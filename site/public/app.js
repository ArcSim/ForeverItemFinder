// The Forever Item Finder site: the item database (built from the addon, data/), the share box, the latest finds.
// Everything players send comes back through textContent only, never as markup.
import { decodeShare } from './share.js';
import { CHIPS, match, rowsOf, catParts } from './filter.js';
import { WhereBlock, sharedSource } from './map.js';

const $ = (id) => document.getElementById(id);
function el(tag, props, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (k === 'class') e.className = v;
    else if (k === 'style') e.style.cssText = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) e.append(kid.nodeType ? kid : String(kid));
  return e;
}

const KIND = { n: 'New', c: 'Changed', h: 'Hotfix', o: 'Classic', x: 'Hidden', u: 'Not Found' };
const PAGE = 100;
let meta, rows = [], byId = new Map(), shown = PAGE, matches = [], selected = null, chip = 'all';
// the category tree's pick ('all', '<class>' or '<class>/<sub>') and whether its types are folded away
let cat = 'all', catShut = false;
const buckets = new Map();

// favorites live in this browser only (no account): a list of item ids
const FAV_KEY = 'fif-favorites';
let favs = new Set();
try { favs = new Set(JSON.parse(localStorage.getItem(FAV_KEY) || '[]')); } catch { favs = new Set(); }
function toggleFav(id) {
  if (favs.has(id)) favs.delete(id); else favs.add(id);
  try { localStorage.setItem(FAV_KEY, JSON.stringify([...favs])); } catch { /* private window: kept for this visit */ }
  filter(true);
  document.querySelectorAll(`[data-star="${id}"]`).forEach(setStar);
}
const SVG = 'http://www.w3.org/2000/svg';
function starIcon() {
  const s = document.createElementNS(SVG, 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  const p = document.createElementNS(SVG, 'path');
  p.setAttribute('d', 'M12 2.6l2.9 6 6.6.9-4.8 4.6 1.2 6.6L12 17.6l-5.9 3.1 1.2-6.6-4.8-4.6 6.6-.9z');
  s.append(p);
  return s;
}
function setStar(b) {
  const on = favs.has(Number(b.dataset.star));
  b.classList.toggle('on', on);
  b.setAttribute('aria-pressed', on ? 'true' : 'false');
  b.title = on ? 'Remove from favorites' : 'Add to favorites';
}
function starButton(id) {
  const b = el('button', { class: 'star', 'data-star': id, type: 'button',
    onclick: (e) => { e.stopPropagation(); toggleFav(id); } }, starIcon());
  setStar(b);
  return b;
}
// the bare star a database row leads with: a click marks it without opening the item
function rowStar(id) {
  const b = starButton(id);
  b.className = 'rstar' + (favs.has(id) ? ' on' : '');
  b.addEventListener('keydown', (e) => e.stopPropagation());
  return b;
}

// an item's icon from the client's art (icons/<file id>.png); an item with none, or art we could not get, shows the
// game's question mark as the game does, and a drawn one while that file is missing too
const NO_ICON = 134400;
function iconEl(r, size) {
  const box = el('span', { class: 'icon', style: `width:${size}px;height:${size}px;border-color:#${qualityHex(r.q)}` });
  const img = el('img', { src: `icons/${r.icon || NO_ICON}.png`, alt: '', loading: 'lazy', width: size - 2, height: size - 2 });
  img.addEventListener('error', () => {
    if (!img.src.endsWith(`/${NO_ICON}.png`)) { img.src = `icons/${NO_ICON}.png`; return; }
    img.replaceWith(el('span', { class: 'qmark', style: `font-size:${Math.round(size * 0.62)}px`, 'aria-hidden': 'true' }, '?'));
  });
  box.append(img);
  return box;
}

// the item's page on Wowhead's Forever database, in a new tab
function wowheadLink(id) {
  return el('a', { class: 'wh', href: `https://www.wowhead.com/forever/item=${id}`, target: '_blank', rel: 'noopener noreferrer',
    title: 'Open this item on Wowhead' }, 'Wowhead');
}

// the item's tooltip on hover, as the game draws it
const tt = el('div', { class: 'tt hidden', role: 'tooltip' });
document.body.append(tt);
let ttFor = null;
const canHover = window.matchMedia('(hover: hover)').matches;
function placeTip(e) {
  const pad = 14, w = tt.offsetWidth, h = tt.offsetHeight;
  let x = e.clientX + pad, y = e.clientY + pad;
  if (x + w > window.innerWidth - 8) x = e.clientX - w - pad;
  if (y + h > window.innerHeight - 8) y = Math.max(8, window.innerHeight - h - 8);
  tt.style.left = Math.max(8, x) + 'px';
  tt.style.top = y + 'px';
}
async function showTip(r, e) {
  ttFor = r.id;
  const d = await bucket(r.id);
  if (ttFor !== r.id) return;
  const lines = [];
  if (d && d.tip) {
    d.tip.slice(1).forEach(([text, hex, right]) => lines.push(el('div', { style: `color:#${hex}` }, el('span', {}, text), right ? el('span', {}, right) : null)));
  } else if (d) {
    lines.push(el('div', {}, el('span', {}, d.line)), el('div', {}, el('span', {}, d.req)));
  }
  tt.replaceChildren(el('div', { class: 'tt-head' }, iconEl(r, 36), el('b', { style: `color:#${qualityHex(r.q)}` }, r.name)), ...lines);
  tt.classList.remove('hidden');
  placeTip(e);
}
function hideTip() { ttFor = null; tt.classList.add('hidden'); }

const qualityHex = (q) => (meta && meta.quality[q]) || 'BFAE8C';
const day = (t) => (t ? new Date(t * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : '');

// pages, from the address: the home page, #db, #share, #latest, #item/<id>
const TABS = ['home', 'db', 'share', 'latest'];
function route() {
  const h = location.hash.replace(/^#/, '');
  const m = h.match(/^item\/(\d+)$/);
  const tab = m ? 'db' : (TABS.includes(h) ? h : 'home');
  for (const t of TABS) $('tab-' + t).classList.toggle('hidden', t !== tab);
  $('topbar').classList.toggle('hidden', tab === 'home');
  $('tabs').classList.toggle('hidden', tab === 'home');
  document.querySelectorAll('nav.tabs a').forEach((a) => a.classList.toggle('on', a.dataset.tab === tab));
  if (m) showItem(Number(m[1]));
  else window.scrollTo(0, 0);
  if (tab === 'latest' || tab === 'home') loadLatest();
}
window.addEventListener('hashchange', route);

// the database
function option(sel, value, text) { sel.append(el('option', { value }, text)); }
function fillFilters() {
  const q = $('fQuality');
  option(q, '', 'Any quality');
  ['Poor', 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary'].forEach((t, i) => option(q, i, t));
  const s = $('fSlot');
  option(s, '', 'Any slot');
  for (const [g, name] of meta.slots) option(s, g, name);
  const c = $('fClass');
  option(c, '', 'Any class');
  meta.classes.forEach((name, i) => option(c, i, name));
  const src = $('fSource');
  option(src, '', 'Any source');
  for (const [bit, text] of meta.sources) option(src, bit, text);
}
function fillDungeons() {
  const bit = Number($('fSource').value);
  const d = $('fDungeon');
  const list = bit === 1 ? meta.raids : bit === 2 ? meta.dungeons : null;
  d.classList.toggle('hidden', !list);
  if (!list) { d.value = ''; return; }
  const keep = d.value;
  d.replaceChildren();
  option(d, '', bit === 1 ? 'Any raid' : 'Any dungeon');
  for (const name of list) option(d, name, name);
  d.value = list.includes(keep) ? keep : '';
}

// keep: a star click keeps the rows already shown, so the list does not jump
function filter(keep) {
  const text = $('q').value.trim().toLowerCase();
  const q = $('fQuality').value, slot = $('fSlot').value, cls = $('fClass').value, src = $('fSource').value;
  const dg = $('fDungeon').classList.contains('hidden') ? '' : $('fDungeon').value;
  const lo = $('fMin').value === '' ? null : Number($('fMin').value);
  const hi = $('fMax').value === '' ? null : Number($('fMax').value);
  const num = (v) => (v === '' ? null : Number(v));
  const result = match(rows, { text, q: num(q), slot: num(slot), cls: num(cls), src: num(src), dg, lo, hi, chip, cat }, favs);
  const counts = result.counts;
  drawCats(result.cats);
  matches = result.matches;
  $('chips').replaceChildren(...CHIPS.map(([key, label]) => el('button', { type: 'button', class: 'kind' + (chip === key ? ' on' : ''),
    'aria-pressed': chip === key ? 'true' : 'false', onclick: () => { chip = key; filter(); } }, `${label} ${counts[key].toLocaleString()}`)));
  if (!keep) shown = PAGE;
  drawRows();
}

// the category tree, as the addon draws it: All Items, each category with its count, the picked category's types under
// it; a second click on the picked category folds its types away (its filter stays), a third opens them
function drawCats(n) {
  const box = $('cats');
  if (!box || !meta || !meta.categories) return;
  const [open] = catParts(cat);
  const row = (key, label, count, sub) => el('button', { type: 'button', class: 'cat' + (sub ? ' sub' : '') + (cat === key ? ' on' : ''),
    'aria-pressed': cat === key ? 'true' : 'false', onclick: () => {
      if (key === cat && !sub && key !== 'all') catShut = !catShut; else { cat = key; catShut = false; }
      filter();
    } }, el('span', {}, label), el('span', { class: 'n' }, count ? count.toLocaleString() : ''));
  const out = [row('all', 'All Items', n.all)];
  for (const [cls, name, subs] of meta.categories) {
    out.push(row(String(cls), name, n[cls]));
    if (!catShut && open === cls) for (const [sc, sname] of subs) out.push(row(cls + '/' + sc, sname, n[cls + '/' + sc], true));
  }
  box.replaceChildren(...out);
}

// a list row; database rows lead with the favorite star, as the addon's do
function rowEl(r, onPick, withStar) {
  const sub = [r.req > 0 ? 'Level ' + r.req : null, r.dungeon || r.zones.split('|')[0] || null].filter(Boolean).join(' · ');
  const tag = r.nf && r.kind !== 'x' ? 'u' : r.kind;
  const row = el('div', { class: 'row' + (withStar ? ' starred' : '') + (selected === r.id ? ' on' : ''), role: 'button', tabindex: '0', 'data-id': r.id,
    onclick: () => { hideTip(); onPick(); }, onkeydown: (e) => { if (e.key === 'Enter' && e.target === row) onPick(); } },
    withStar ? rowStar(r.id) : null,
    iconEl(r, 34),
    el('span', { class: 'nm', style: `color:#${qualityHex(r.q)}` }, r.name),
    el('span', { class: 'chip ' + tag }, KIND[tag] || ''),
    sub ? el('span', { class: 'sub' }, sub) : null);
  if (canHover) {
    row.addEventListener('mouseenter', (e) => showTip(r, e));
    row.addEventListener('mousemove', (e) => { if (ttFor === r.id && !tt.classList.contains('hidden')) placeTip(e); });
    row.addEventListener('mouseleave', hideTip);
  }
  return row;
}

function drawRows() {
  const box = $('rows');
  box.replaceChildren(...matches.slice(0, shown).map((r) => rowEl(r, () => { location.hash = 'item/' + r.id; }, true)));
  if (matches.length === 0) box.append(el('div', { class: 'empty' }, 'No items match.'));
  $('count').textContent = matches.length === rows.length ? `${rows.length.toLocaleString()} items` :
    `${matches.length.toLocaleString()} of ${rows.length.toLocaleString()} items`;
  $('more').classList.toggle('hidden', matches.length <= shown);
}

async function bucket(id) {
  const b = id % meta.buckets;
  if (!buckets.has(b)) buckets.set(b, fetch(`data/items/${b}.json`).then((r) => r.json()));
  return (await buckets.get(b))[id];
}

// the spots of an item's mobs and objects, each kept once in the file of its id
const spotFiles = new Map();
async function placeSpots(d) {
  const out = {};
  const keys = [...new Set((d.map || []).filter((e) => e.s).flatMap((e) => [].concat(e.s)))];
  await Promise.all(keys.map(async (k) => {
    const b = Number(k.slice(1)) % meta.buckets;
    if (!spotFiles.has(b)) spotFiles.set(b, fetch(`data/spots/${b}.json`).then((r) => r.json()));
    out[k] = (await spotFiles.get(b))[k];
  }));
  return out;
}

async function showItem(id) {
  selected = id;
  document.querySelectorAll('#rows .row').forEach((e) => e.classList.toggle('on', Number(e.dataset.id) === id));
  const body = $('itemBody');
  const r = byId.get(id);
  if (!meta) return;
  const d = await bucket(id);
  const spots = d ? await placeSpots(d) : {};
  if (selected !== id) return;
  if (!r || !d) {
    body.replaceChildren(el('div', { class: 'empty' }, `Item ${id} is not in the database yet.`));
    return;
  }
  const facts = el('dl', { class: 'facts' });
  for (const [k, v] of d.status) {
    if (k === 'Found') continue;
    facts.append(el('dt', {}, k), el('dd', {}, v));
  }
  const foundDd = el('dd', {}, d.status.find((s) => s[0] === 'Found')?.[1] || 'Not yet in Forever');
  facts.append(el('dt', {}, 'Found'), foundDd);
  const where = new WhereBlock(d, meta, spots);
  const parts = [
    el('div', { class: 'item-head' }, iconEl(r, 52),
      el('div', {}, el('h3', { style: `color:#${qualityHex(r.q)}` }, r.name), el('div', { class: 'line' }, d.line), el('div', { class: 'req' }, d.req)),
      el('div', { class: 'head-btns' }, wowheadLink(id), starButton(id))),
    facts,
  ];
  if (d.where.length) parts.push(el('h4', {}, 'Where it drops'), where.el);
  else parts.push(el('p', { class: 'note' }, 'Not found in game yet. The first player to loot it fills this in.'));
  if (d.tip) {
    const tip = el('div', { class: 'tip' });
    for (const [text, hex, right] of d.tip) {
      tip.append(el('div', { style: `color:#${hex}` }, el('span', {}, text), right ? el('span', {}, right) : null));
    }
    parts.push(el('h4', {}, 'Tooltip'), tip);
  }
  const shared = el('div', {});
  parts.push(el('h4', {}, 'Shared by players'), shared);
  body.replaceChildren(...parts);
  where.shown();
  // on a phone the item sits under the list
  if (window.matchMedia('(max-width: 860px)').matches) $('item').scrollIntoView({ block: 'start' });
  // what players shared for it
  shared.append(el('p', { class: 'note' }, 'Loading...'));
  try {
    const f = await (await fetch(`api/finds?id=${id}`)).json();
    if (selected !== id) return;
    shared.replaceChildren();
    if (!f) {
      shared.append(el('p', { class: 'note' }, 'Nobody has shared it yet.'));
      return;
    }
    const n = f.sharers;
    foundDd.textContent = `${f.find.found_at ? day(f.find.found_at) + ', ' : ''}${n} ${n === 1 ? 'player' : 'players'}`;
    if (f.sources.length === 0) shared.append(el('p', { class: 'note' }, `Shared by ${n} ${n === 1 ? 'player' : 'players'}.`));
    for (const s of f.sources) {
      const t = sharedSource(s, d.map, meta.zones || {});
      shared.append(el('div', { class: 'where' }, el('div', {}, el('span', {}, t.who), el('span', {}, t.where))));
    }
  } catch {
    shared.replaceChildren(el('p', { class: 'note' }, 'Shared finds could not be loaded right now.'));
  }
}

// the share box: read the paste as the addon writes it, then send it
let pasted = null;
$('paste').addEventListener('input', () => {
  const text = $('paste').value;
  const read = $('read');
  pasted = null;
  $('send').disabled = true;
  if (!text.trim()) { read.textContent = ''; read.className = 'read'; return; }
  const s = decodeShare(text);
  if (!s) {
    read.textContent = 'That is not a Forever Item Finder share text. Press Share your finds in the addon and copy all of it.';
    read.className = 'read bad';
    return;
  }
  pasted = text;
  $('send').disabled = s.finds.length === 0;
  if (s.finds.length < s.count) {
    read.textContent = `Only ${s.finds.length} of ${s.count} finds came through: the copy may have been cut. You can share these, or copy it again.`;
    read.className = 'read warn';
  } else {
    read.textContent = `${s.finds.length} ${s.finds.length === 1 ? 'find' : 'finds'} ready to share.`;
    read.className = 'read ok';
  }
});
$('send').addEventListener('click', async () => {
  if (!pasted) return;
  const read = $('read');
  $('send').disabled = true;
  read.textContent = 'Sharing...';
  read.className = 'read';
  try {
    const r = await (await fetch('api/share', { method: 'POST', headers: { 'content-type': 'text/plain' }, body: pasted })).json();
    if (!r.ok) {
      read.textContent = r.error || 'That did not work. Please try again.';
      read.className = 'read bad';
      $('send').disabled = false;
      return;
    }
    read.textContent = r.added > 0 ? `Thanks! ${r.added} new ${r.added === 1 ? 'find' : 'finds'} added, ${r.known} the site already had.` :
      `Thanks! The site already had all ${r.known} of these.`;
    read.className = 'read ok';
    $('paste').value = '';
    pasted = null;
  } catch {
    read.textContent = 'The site could not be reached. Please try again.';
    read.className = 'read bad';
    $('send').disabled = false;
  }
});

// the latest shared finds: the Latest finds page, the home page's five and its numbers
function latestRow(f) {
  const known = byId.get(f.id);
  const row = known ? { ...known } : { id: f.id, name: `Item ${f.id}`, q: f.q ?? -1, kind: f.k, req: 0, dungeon: '', zones: '' };
  const e = rowEl(row, () => { location.hash = 'item/' + f.id; });
  e.querySelector('.sub')?.remove();
  e.append(el('span', { class: 'sub' }, [day(f.found_at), (meta.zones || {})[f.m],
    `${f.sharers} ${f.sharers === 1 ? 'player' : 'players'}`].filter(Boolean).join(' · ')));
  return e;
}
async function loadLatest() {
  const box = $('latestRows');
  const home = $('homeLatest');
  try {
    const r = await (await fetch('api/finds')).json();
    const shared = `${r.total.toLocaleString()} ${r.total === 1 ? 'find' : 'finds'} shared so far`;
    $('latestCount').textContent = shared;
    $('stats').textContent = (meta ? `${meta.items.toLocaleString()} items in the database · ` : '') + shared;
    for (const [target, list] of [[box, r.latest], [home, r.latest.slice(0, 5)]]) {
      target.replaceChildren(...list.map(latestRow));
      if (list.length === 0) target.append(el('div', { class: 'empty' }, 'Nothing shared yet. Be the first!'));
    }
  } catch {
    for (const target of [box, home]) target.replaceChildren(el('div', { class: 'empty' }, 'The latest finds could not be loaded right now.'));
  }
}

// start: the database files, then whatever the address asks for
(async () => {
  meta = await (await fetch('data/meta.json')).json();
  const index = await (await fetch('data/index.json')).json();
  rows = rowsOf(index);
  // as in the addon: Forever's own items first, newest first, old Classic items after
  rows.sort((a, b) => ((a.kind === 'o') - (b.kind === 'o')) || (b.id - a.id));
  for (const r of rows) byId.set(r.id, r);
  fillFilters();
  for (const id of ['q', 'fQuality', 'fSlot', 'fClass', 'fDungeon', 'fMin', 'fMax']) $(id).addEventListener('input', filter);
  $('fSource').addEventListener('input', () => { fillDungeons(); filter(); });
  $('more').addEventListener('click', () => { shown += PAGE; drawRows(); });
  filter();
  route();
})();
// the page shows at once; the database fills in when its files arrive
route();
