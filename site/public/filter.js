// The database filter, shared by the page and its tests: the addon's chips (New is a new item the beta showed or with a
// known place, Not Found every other new or hidden one, hotfixes count as Changed) plus Favorites, counted over what the
// other filters leave, as in the addon. New, Changed, Classic and Not Found add up to All.
export const CHIPS = [['all', 'All'], ['n', 'New'], ['c', 'Changed'], ['o', 'Classic'], ['u', 'Not Found'], ['f', 'Favorites']];
export const chipKind = (r) => (r.nf ? 'u' : r.kind === 'o' ? 'o' : r.kind === 'n' || r.kind === 'x' ? 'n' : 'c');

// a category key: 'all', '<item class>' or '<item class>/<subclass>' -> [class, subclass] (null = any)
export function catParts(cat) {
  const m = /^(-?\d+)(?:\/(-?\d+))?$/.exec(cat || '');
  return m ? [Number(m[1]), m[2] !== undefined ? Number(m[2]) : null] : [null, null];
}

// f: { text, q, slot, cls, src, dg, lo, hi, chip, cat } (null or '' = any); favs: a Set of item ids. As in the addon, the
// chips count what the category keeps and the categories (cats: all, '<class>', '<class>/<sub>') count what the chip keeps
export function match(rows, f, favs) {
  const counts = { all: 0, n: 0, c: 0, o: 0, u: 0, f: 0 };
  const cats = { all: 0 };
  const [cc, cs] = catParts(f.cat);
  const matches = rows.filter((r) => {
    if (f.text && !r.find.includes(f.text)) return false;
    if (f.q !== null && f.q !== undefined && r.q !== f.q) return false;
    if (f.slot !== null && f.slot !== undefined && r.slot !== f.slot) return false;
    if (f.cls !== null && f.cls !== undefined && !(r.use & (1 << f.cls))) return false;
    if (f.src && !(r.src & f.src)) return false;
    if (f.dg && r.dungeon !== f.dg) return false;
    if (f.lo !== null && f.lo !== undefined && r.req < f.lo) return false;
    if (f.hi !== null && f.hi !== undefined && r.req > f.hi) return false;
    const k = chipKind(r), fav = favs.has(r.id);
    const chip = f.chip || 'all';
    const inChip = chip === 'all' || chip === k || (chip === 'f' && fav);
    const inCat = cc === null || (r.ic === cc && (cs === null || r.isc === cs));
    if (inCat) {
      counts.all++;
      counts[k]++;
      if (fav) counts.f++;
    }
    if (inChip) {
      cats.all++;
      cats[r.ic] = (cats[r.ic] || 0) + 1;
      cats[r.ic + '/' + r.isc] = (cats[r.ic + '/' + r.isc] || 0) + 1;
    }
    return inChip && inCat;
  });
  return { matches, counts, cats };
}

// index.json rows as the page uses them
export function rowsOf(index) {
  return index.map(([id, name, q, kind, req, ilvl, slot, use, src, dungeon, zones, nf, icon, ic, isc]) =>
    ({ id, name, q, kind, req, ilvl, slot, use, src, dungeon, zones, nf, icon, ic, isc, find: (name + '|' + zones).toLowerCase() }));
}
