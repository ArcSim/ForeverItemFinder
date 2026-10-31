// An item's "Where it drops" block as the addon draws it: the zone's map with every spot of every source (spots closer
// than a pin at the current zoom share one pin, only pins in view are drawn), zone chips for an item in several zones,
// a hover card per pin, and one line per source; a lit line lights its pins and dims the rest.
// The logic is plain functions so the tests can run it without a page.

// the addon's pin looks: size, ring width, ring, fill, centre
export const LOOK = { drop: [10, 2, '3A0A08', 'FF4A30'], vendor: [12, 2, '3B2A08', 'FFD100'], world: [12, 2, '3A1A00', 'FF8A2A'],
  quest: [12, 2, '0A2440', '4FA3FF'], object: [10, 2, '16300A', '7DCB4F'], skin: [12, 2, '0A302A', '38C5B0'], entrance: [16, 3, 'B57CFF', '6B3FB0', '2A1745'] };
const RANK = ['', 'Elite', 'Rare Elite', 'Boss', 'Rare'];
export const PIN = 10, MAX_Z = 4, OPEN_Z = 2.5, MARGIN = 0.08, STEP = 1.25;
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
const xy = (p) => (p.x / 10).toFixed(1) + ', ' + (p.y / 10).toFixed(1);

// an entry's pins, { m, x, y } in the addon's order, from its own list or its places' shared ones (a node under
// several records names each)
export function pinsOf(entry, spots) {
  const lists = entry.p ? [entry.p] : [].concat(entry.s || []).map((k) => spots[k] || []);
  const out = [];
  for (const list of lists) for (const [m, coords] of list) for (let i = 0; i + 1 < coords.length; i += 2) out.push({ m, x: coords[i], y: coords[i + 1] });
  return out;
}

// every zone with pins the site has a picture of, in the lines' order, with its spot count; a zone holding only a
// dungeon's entrance goes by the dungeon's name
export function zonesOf(entries, pins, art) {
  const list = [], count = {}, entrance = {};
  entries.forEach((e, i) => {
    for (const p of pins[i]) {
      if (!art[p.m]) continue;
      if (count[p.m] === undefined) { list.push(p.m); count[p.m] = 0; }
      count[p.m]++;
      if (e.k !== 'entrance') entrance[p.m] = false;
      else if (entrance[p.m] === undefined) entrance[p.m] = e.d;
    }
  });
  return { list, count, entrance };
}

// the zone on the map: the picked chip, else the lit line's first zone, else the first zone
export function mapFor(zone, hi, zones, pins, art) {
  if (zone !== null && zones.count[zone]) return zone;
  if (hi !== null) for (const p of pins[hi]) if (art[p.m]) return p.m;
  return zones.list.length ? zones.list[0] : null;
}

// every spot on map m, the lit source's first so its pins win a shared cell
export function spotsOn(m, hi, pins) {
  const out = [];
  const add = (ei) => { for (const p of pins[ei]) if (p.m === m) out.push({ x: p.x, y: p.y, ei }); };
  if (hi !== null) add(hi);
  pins.forEach((_, ei) => { if (ei !== hi) add(ei); });
  return out;
}

// the first spot in each cell of cw x ch (per mille, worked out as the addon does so a spot on a cell's edge lands
// in the same cell) keeps it
export function thin(spots, cw, ch) {
  const taken = new Set(), out = [];
  for (const s of spots) {
    const cell = Math.floor(s.x / cw) * 100000 + Math.floor(s.y / ch);
    if (taken.has(cell)) continue;
    taken.add(cell);
    out.push(s);
  }
  return out;
}

// the view that frames every spot: zoom, and the map's left and top edge in view (fractions)
export function fit(spots) {
  if (!spots.length) return { z: 1, vx: 0, vy: 0 };
  let x0 = 1, y0 = 1, x1 = 0, y1 = 0;
  for (const s of spots) {
    const x = s.x / 1000, y = s.y / 1000;
    x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
  }
  const z = clamp(Math.min(OPEN_Z, 1 / (x1 - x0 + 2 * MARGIN), 1 / (y1 - y0 + 2 * MARGIN)), 1, MAX_Z);
  return view(z, (x0 + x1) / 2 - 0.5 / z, (y0 + y1) / 2 - 0.5 / z);
}
export function view(z, vx, vy) {
  z = clamp(z, 1, MAX_Z);
  return { z, vx: clamp(vx, 0, 1 - 1 / z), vy: clamp(vy, 0, 1 - 1 / z) };
}
// zoom by k keeping the point at (cx, cy) of the frame where it is
export function zoomAt(v, cx, cy, k) {
  const z = clamp(v.z * k, 1, MAX_Z);
  return view(z, v.vx + cx / v.z - cx / z, v.vy + cy / v.z - cy / z);
}

// the short spot a source line ends with: coordinates for one spot on the map, a count for several, the zone of its
// first spot when none is on the map, nothing for a world drop (its pins are a few of many)
export function spotText(entry, pins, shown, names) {
  const p = pins[0];
  if (!p || entry.k === 'world') return '';
  let n = 0, here = null;
  for (const q of pins) if (q.m === shown) { n++; here = here || q; }
  if (n === 0) return names[p.m] || '';
  return n === 1 ? xy(here) : n + ' spots';
}

// each where line's right side: with a map, its entry's own text or its spot on the shown map; without one (or for a
// line lighting nothing) the text the addon worked out
export function lineRights(d, entries, pins, shown, names) {
  return d.where.map((_, i) => {
    const li = (d.lines && d.lines[i]) || 0;
    const e = li > 0 ? entries[li - 1] : null;
    if (shown === null || !e) return d.spots[i] || '';
    return e.t !== undefined ? e.t : spotText(e, pins[li - 1], shown, names);
  });
}

// the map's caption: the zone, and the dungeon when a pin on it is that dungeon's entrance
export function captionOf(m, spots, entries, names) {
  let dungeon = null;
  for (const s of spots) if (entries[s.ei].k === 'entrance') { dungeon = entries[s.ei].d; break; }
  const zone = names[m] || '';
  return dungeon ? (zone ? zone + ', ' + dungeon : dungeon) : zone;
}

// a zone chip's words: the zone and its spot count, or the dungeon for a zone holding only its entrance
export function zoneLabel(m, zones, names) {
  return zones.entrance[m] || (names[m] || 'Zone ' + m) + ' ' + zones.count[m];
}

// how many chips fit beside the "+N more" list (all when they fit on their own), the shown zone moved into the last
// place when it would be in the list
export function chipRow(list, widths, avail, moreW, shown, gap) {
  const order = list.slice();
  const total = widths.reduce((a, w) => a + w + gap, -gap);
  if (total <= avail) return { order, fit: order.length };
  const w = widths.slice();
  let x = 0, fitN = 0;
  for (let i = 0; i < order.length; i++) {
    if (x + w[i] + gap + moreW > avail) break;
    x += w[i] + gap;
    fitN = i + 1;
  }
  fitN = Math.max(fitN, 1);
  const at = order.indexOf(shown);
  if (at >= fitN) [order[fitN - 1], order[at]] = [order[at], order[fitN - 1]];
  return { order, fit: fitN };
}

// the hover card's lines for a spot
export function cardOf(entry, s, m, names) {
  const w = entry.w || ['', '', 0];
  let level = w[1] ? 'Level ' + w[1] : '';
  const rank = RANK[w[2] || 0];
  if (rank) level = level ? level + ' ' + rank : rank;
  const at = xy(s);
  return { name: w[0], level, role: entry.r || '', place: entry.d ? entry.d + ' entrance  ' + at : (names[m] ? names[m] + '  ' : '') + at };
}

const hex = (h, a) => `rgba(${parseInt(h.slice(0, 2), 16)},${parseInt(h.slice(2, 4), 16)},${parseInt(h.slice(4, 6), 16)},${a})`;
function dotStyle(look) {
  const L = LOOK[look] || LOOK.drop;
  const fill = L[4] ? `radial-gradient(circle, #${L[4]} 0 18%, #${L[3]} 19%)` : '#' + L[3];
  return `width:${L[0]}px;height:${L[0]}px;background:${fill};border:${L[1]}px solid #${L[2]};box-shadow:0 0 0 ${Math.round(L[0] * 0.4)}px ${hex(L[3], 0.3)}`;
}
// a line's dot wears its pins' colour, an entrance its ring's
const dotHex = (look) => { const L = LOOK[look] || LOOK.drop; return look === 'entrance' ? L[2] : L[3]; };

function h(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

// the block: d is the item's data, meta the site's, spots its places' shared spots
export class WhereBlock {
  constructor(d, meta, spots) {
    this.d = d;
    this.names = meta.zones || {};
    this.art = meta.art || {};
    this.entries = d.map || [];
    this.pins = this.entries.map((e) => pinsOf(e, spots));
    this.zones = zonesOf(this.entries, this.pins, this.art);
    this.zone = null;
    this.hi = null;
    this.v = null;
    this.key = null;
    this.W = 434;
    this.drag = null;
    this.touches = new Map();
    this.el = h('div', 'whereblock');
    this.hasMap = this.zones.list.length > 0;
    if (this.hasMap) this.buildMap();
    this.lines = h('div', 'where' + (this.hasMap ? ' picks' : ''));
    this.el.append(this.lines);
    this.render();
  }

  buildMap() {
    const box = this.box = h('div', 'map');
    this.art_ = h('img', 'art');
    this.art_.alt = '';
    this.art_.draggable = false;
    this.layer = h('div', 'pins');
    this.chips = h('div', 'zchips');
    this.cap = h('div', 'cap');
    this.card = h('div', 'card hidden');
    this.card.setAttribute('role', 'tooltip');
    const zoom = h('div', 'zoom');
    const btn = (label, text, fn, cls) => {
      const b = h('button', cls, text);
      b.type = 'button';
      b.setAttribute('aria-label', label);
      b.addEventListener('click', fn);
      return b;
    };
    zoom.append(btn('Zoom in', '+', () => this.setView(zoomAt(this.v, 0.5, 0.5, STEP))),
      btn('Zoom out', '−', () => this.setView(zoomAt(this.v, 0.5, 0.5, 1 / STEP))),
      btn('Frame every spot', 'Reset', () => { this.v = null; this.render(); }, 'reset'));
    box.append(this.art_, this.layer, this.chips, this.cap, zoom, this.card);
    this.pool = [];
    box.addEventListener('wheel', (e) => {
      e.preventDefault();
      const r = box.getBoundingClientRect();
      this.setView(zoomAt(this.v, (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height, e.deltaY < 0 ? STEP : 1 / STEP));
    }, { passive: false });
    box.addEventListener('pointerdown', (e) => this.down(e));
    box.addEventListener('pointermove', (e) => this.move(e));
    for (const ev of ['pointerup', 'pointercancel']) box.addEventListener(ev, (e) => this.up(e));
    box.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') this.up(e); });
    this.layer.addEventListener('pointerover', (e) => {
      const p = e.target.closest('.pin');
      if (p && e.pointerType === 'mouse' && !this.drag) this.showCard(p);
    });
    this.layer.addEventListener('pointerout', (e) => { if (e.target.closest('.pin')) this.hideCard(); });
    this.layer.addEventListener('click', (e) => {
      const p = e.target.closest('.pin');
      if (!p || this.moved) return;
      // a pin is on the map shown, so lighting its source keeps that map
      const ei = Number(p.dataset.ei);
      this.hi = this.hi === ei ? null : ei;
      this.zone = this.m;
      this.render();
    });
    this.el.append(box);
    if (typeof ResizeObserver !== 'undefined') {
      new ResizeObserver(() => {
        const w = box.clientWidth;
        if (w && Math.abs(w - this.W) > 1) { this.W = w; this.render(); }
      }).observe(box);
    }
  }

  setView(v) { this.v = v; this.hideCard(); this.drawPins(); }

  down(e) {
    if (e.target.closest('.zoom, .zchips')) return;
    if (e.button !== 0 && e.pointerType === 'mouse') return;
    const r = this.box.getBoundingClientRect();
    this.touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
    this.moved = false;
    if (this.touches.size === 2) {
      // two fingers: pinch to zoom around their middle
      const [a, b] = [...this.touches.values()];
      this.drag = { pinch: Math.hypot(a.x - b.x, a.y - b.y), v: this.v, r };
    } else {
      this.drag = { x: e.clientX, y: e.clientY, v: this.v, r };
    }
  }
  move(e) {
    const d = this.drag;
    if (!d || !this.touches.has(e.pointerId)) return;
    this.touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (d.pinch) {
      if (this.touches.size < 2) return;
      const [a, b] = [...this.touches.values()];
      const cx = ((a.x + b.x) / 2 - d.r.left) / d.r.width, cy = ((a.y + b.y) / 2 - d.r.top) / d.r.height;
      this.moved = true;
      this.setView(zoomAt(d.v, cx, cy, Math.hypot(a.x - b.x, a.y - b.y) / d.pinch));
      return;
    }
    if (Math.abs(e.clientX - d.x) + Math.abs(e.clientY - d.y) > 3) {
      if (!this.moved) { this.moved = true; this.box.classList.add('dragging'); this.box.setPointerCapture?.(e.pointerId); }
      this.setView(view(d.v.z, d.v.vx - (e.clientX - d.x) / d.r.width / d.v.z, d.v.vy - (e.clientY - d.y) / d.r.height / d.v.z));
    }
  }
  up(e) {
    this.touches.delete(e.pointerId);
    if (!this.drag) return;
    if (this.touches.size === 0) {
      this.drag = null;
      this.box.classList.remove('dragging');
    } else if (this.drag.pinch) {
      // one finger left after a pinch carries on as a drag from where it is
      const [t] = [...this.touches.values()];
      this.drag = { x: t.x, y: t.y, v: this.v, r: this.drag.r };
    }
  }

  showCard(p) {
    const s = this.drawn[Number(p.dataset.i)];
    if (!s) return;
    const c = cardOf(this.entries[s.ei], s, this.m, this.names);
    const kids = [h('div', 'cn', c.name), c.level ? h('div', 'cl', c.level) : null, c.role ? h('div', '', c.role) : null, h('div', 'cp', c.place)];
    this.card.replaceChildren(...kids.filter(Boolean));
    const sx = (s.x / 1000 - this.v.vx) * this.v.z, sy = (s.y / 1000 - this.v.vy) * this.v.z;
    const st = this.card.style;
    st.left = sx < 0.55 ? `calc(${(sx * 100).toFixed(2)}% + 14px)` : '';
    st.right = sx < 0.55 ? '' : `calc(${((1 - sx) * 100).toFixed(2)}% + 14px)`;
    st.top = `clamp(4px, calc(${(sy * 100).toFixed(2)}% - 24px), calc(100% - 104px))`;
    this.card.classList.remove('hidden');
  }
  hideCard() { if (this.card) this.card.classList.add('hidden'); }

  // the map, the chips and the lines for the current zone and lit line
  render() {
    const m = this.m = this.hasMap ? mapFor(this.zone, this.hi, this.zones, this.pins, this.art) : null;
    if (this.hasMap) {
      this.spots = spotsOn(m, this.hi, this.pins);
      const key = m;
      if (this.key !== key || !this.v) { this.key = key; this.v = fit(this.spots); }
      if (this.art_.dataset.m !== String(m)) {
        this.art_.dataset.m = String(m);
        this.art_.src = `maps/${m}.jpg`;
        this.art_.alt = 'Map of ' + (this.names[m] || 'the zone');
      }
      this.cap.textContent = captionOf(m, this.spots, this.entries, this.names);
      this.thinFor = null;
      this.hideCard();
      this.drawPins();
      this.layChips();
    }
    this.drawLines();
  }

  drawPins() {
    if (!this.box) return;
    const v = this.v, W = this.W, H = W * 668 / 1002;
    // the thinned spots stay while the zoom does, so a drag only moves pins
    const tkey = this.m + ':' + this.hi + ':' + v.z + ':' + W;
    if (this.thinFor !== tkey) { this.thinFor = tkey; this.thinned = thin(this.spots, PIN / (W * v.z) * 1000, PIN / (H * v.z) * 1000); }
    this.art_.style.transform = `scale(${v.z}) translate(${(-v.vx * 100).toFixed(3)}%, ${(-v.vy * 100).toFixed(3)}%)`;
    const drawn = this.drawn = [];
    for (const s of this.thinned) {
      const sx = (s.x / 1000 - v.vx) * v.z, sy = (s.y / 1000 - v.vy) * v.z;
      if (sx < 0 || sx > 1 || sy < 0 || sy > 1) continue;
      drawn.push(s);
      const i = drawn.length - 1;
      let p = this.pool[i];
      if (!p) {
        p = this.pool[i] = h('button', 'pin');
        p.type = 'button';
        p.append(h('span'));
        this.layer.append(p);
      }
      const e = this.entries[s.ei];
      if (p.dataset.look !== e.k) { p.dataset.look = e.k; p.firstChild.style.cssText = dotStyle(e.k); }
      p.dataset.i = i;
      p.dataset.ei = s.ei;
      p.style.left = (sx * 100).toFixed(3) + '%';
      p.style.top = (sy * 100).toFixed(3) + '%';
      p.style.opacity = this.hi !== null && this.hi !== s.ei ? 0.3 : 1;
      p.setAttribute('aria-label', cardOf(e, s, this.m, this.names).name + ', ' + xy(s));
      p.hidden = false;
    }
    for (let i = drawn.length; i < this.pool.length; i++) this.pool[i].hidden = true;
  }

  layChips() {
    const list = this.zones.list;
    const on = list.length > 1;
    this.cap.hidden = on;
    this.chips.replaceChildren();
    if (!on) return;
    const chip = (m) => {
      const b = h('button', 'zchip' + (m === this.m ? ' on' : ''), zoneLabel(m, this.zones, this.names));
      b.type = 'button';
      b.setAttribute('aria-pressed', m === this.m ? 'true' : 'false');
      b.addEventListener('click', () => this.pick(m));
      return b;
    };
    const all = list.map(chip);
    this.chips.append(...all);
    const avail = this.chips.clientWidth;
    // laid out before the page shows it: every chip stays, and the next layout fits them
    if (!avail) return;
    const widths = all.map((b) => b.offsetWidth);
    const label = (n) => `+${n} more`;
    const probe = h('span', 'zchip zprobe');
    this.chips.append(probe);
    let moreW = 0;
    for (const text of [label(list.length), ...list.map((m) => zoneLabel(m, this.zones, this.names))]) {
      probe.textContent = text;
      moreW = Math.max(moreW, probe.offsetWidth);
    }
    probe.remove();
    const { order, fit: n } = chipRow(list, widths, avail, moreW + 18, this.m, 4);
    if (n === list.length) return;
    this.chips.replaceChildren(...order.slice(0, n).map(chip));
    const rest = order.slice(n);
    const sel = h('select', 'zchip zmore');
    sel.setAttribute('aria-label', 'More zones');
    const head = h('option', '', label(rest.length));
    head.disabled = true;
    head.hidden = true;
    head.selected = true;
    sel.append(head, ...rest.map((m) => { const o = h('option', '', zoneLabel(m, this.zones, this.names)); o.value = m; return o; }));
    sel.addEventListener('change', () => this.pick(Number(sel.value)));
    this.chips.append(sel);
  }

  // the shown zone becomes another one: a lit line with no pins there goes dark
  pick(m) {
    if (this.hi !== null && !this.pins[this.hi].some((p) => p.m === m)) this.hi = null;
    this.zone = m;
    this.render();
  }

  drawLines() {
    const d = this.d;
    const rights = lineRights(d, this.entries, this.pins, this.m, this.names);
    const rows = d.where.map((text, i) => {
      const li = (d.lines && d.lines[i]) || 0;
      const e = li > 0 ? this.entries[li - 1] : null;
      const left = h('span', 'l');
      if (this.hasMap && e) {
        const dot = h('span', 'dot');
        dot.style.background = '#' + dotHex(e.k);
        dot.setAttribute('aria-hidden', 'true');
        left.append(dot);
      }
      left.append(h('span', 't', text));
      const row = h(this.hasMap && e ? 'button' : 'div', this.hasMap && e && this.hi === li - 1 ? 'on' : '');
      row.append(left, h('span', 'r', rights[i]));
      if (this.hasMap && e) {
        row.type = 'button';
        row.setAttribute('aria-pressed', this.hi === li - 1 ? 'true' : 'false');
        row.addEventListener('click', () => {
          const ei = li - 1;
          this.hi = this.hi === ei ? null : ei;
          this.zone = this.hi !== null && this.pins[ei].some((p) => p.m === this.m) ? this.m : null;
          this.render();
        });
      }
      return row;
    });
    this.lines.replaceChildren(...rows);
  }

  // after the block is on the page: the map's real width for the pins and the chips
  shown() {
    if (!this.box) return;
    this.W = this.box.clientWidth || this.W;
    this.render();
  }
}
