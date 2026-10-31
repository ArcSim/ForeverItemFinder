// The share store behind /api/share and /api/finds, written against Cloudflare D1 (prepare / bind / first / all /
// batch). A string's finds go in by the chunk as JSON, so a full share stays within a request's query budget.
import { decodeShare } from '../public/share.js';

export const SHARE_LIMIT = 12;     // shares one address may make in an hour
export const MAX_TEXT = 600000;    // characters a share string may have
export const MAX_FINDS = 2000;     // finds read from one string
const CHUNK = 250;

// nothing typed in a pasted string is kept: no credit name (a paste cannot prove who found it) and no place names
// (the page names creatures and zones from its own data, by their ids). The source key columns n and z hold those
// ids as text, so one item keeps a source per creature and map; they are never shown
const num = (v) => (Number.isInteger(v) && v > 0 && v < 100000000 ? v : null);
const rowOf = (f) => {
  const npc = num(f.src?.npc), m = num(f.src?.m);
  return {
    id: f.id, k: f.kind, q: f.q ?? null, il: f.ilvl ?? null, rq: f.req ?? null, cl: f.cls ?? null, sc: f.sub ?? null,
    iv: f.inv ?? null, by: null, at: f.at ?? null,
    t: f.src ? f.src.t : null, n: npc ? String(npc) : '', npc, lv: f.src?.lv ?? null, z: m ? String(m) : '',
    sz: null, x: f.src?.x ?? null, y: f.src?.y ?? null, m,
  };
};
const J = (col) => `json_extract(value, '$.${col}')`;

const KNOWN = `SELECT COUNT(*) AS n FROM finds WHERE id IN (SELECT ${J('id')} FROM json_each(?1))`;
const ADD_FINDS = `INSERT INTO finds (id, k, q, il, rq, cl, sc, iv, by, found_at, added_at)
  SELECT ${J('id')}, ${J('k')}, ${J('q')}, ${J('il')}, ${J('rq')}, ${J('cl')}, ${J('sc')}, ${J('iv')}, ${J('by')}, ${J('at')}, ?2
  FROM json_each(?1) WHERE true
  ON CONFLICT (id) DO UPDATE SET
    k = CASE WHEN excluded.k = 'c' THEN 'c' ELSE finds.k END,
    by = COALESCE(finds.by, excluded.by),
    found_at = CASE WHEN finds.found_at IS NULL THEN excluded.found_at WHEN excluded.found_at IS NULL THEN finds.found_at
      ELSE MIN(finds.found_at, excluded.found_at) END,
    q = COALESCE(finds.q, excluded.q), il = COALESCE(finds.il, excluded.il), rq = COALESCE(finds.rq, excluded.rq),
    cl = COALESCE(finds.cl, excluded.cl), sc = COALESCE(finds.sc, excluded.sc), iv = COALESCE(finds.iv, excluded.iv)`;
const ADD_SEEN = `INSERT OR IGNORE INTO seen (id, sharer) SELECT ${J('id')}, ?2 FROM json_each(?1)`;
const ADD_SOURCES = `INSERT OR IGNORE INTO sources (id, t, n, npc, lv, z, sz, x, y, m)
  SELECT ${J('id')}, ${J('t')}, ${J('n')}, ${J('npc')}, ${J('lv')}, ${J('z')}, ${J('sz')}, ${J('x')}, ${J('y')}, ${J('m')}
  FROM json_each(?1) WHERE ${J('t')} IS NOT NULL`;

// text: what the player pasted; ipKey: a salted hash of their address; now: seconds
export async function share(db, text, ipKey, now) {
  if (typeof text !== 'string' || text.length > MAX_TEXT) {
    return { ok: false, status: 413, error: 'That is far longer than a share string.' };
  }
  const s = decodeShare(text);
  if (!s) return { ok: false, status: 400, error: 'That is not a Forever Item Finder share string.' };
  const recent = await db.prepare('SELECT COUNT(*) AS n FROM shares WHERE key = ?1 AND at > ?2').bind(ipKey, now - 3600).first();
  if (recent && recent.n >= SHARE_LIMIT) {
    return { ok: false, status: 429, error: 'Lots of shares from here in the last hour: please try again later.' };
  }
  // one row per item, the first the string carries
  const seenIds = new Set();
  const finds = [];
  for (const f of s.finds) {
    if (finds.length >= MAX_FINDS) break;
    if (!seenIds.has(f.id)) { seenIds.add(f.id); finds.push(f); }
  }
  const sharer = String(s.install).slice(0, 16);
  const stmts = [
    db.prepare('INSERT INTO shares (key, at) VALUES (?1, ?2)').bind(ipKey, now),
    db.prepare('DELETE FROM shares WHERE at < ?1').bind(now - 7200),
  ];
  let known = 0;
  for (let i = 0; i < finds.length; i += CHUNK) {
    const json = JSON.stringify(finds.slice(i, i + CHUNK).map(rowOf));
    const k = await db.prepare(KNOWN).bind(json).first();
    known += k ? k.n : 0;
    stmts.push(db.prepare(ADD_FINDS).bind(json, now), db.prepare(ADD_SEEN).bind(json, sharer), db.prepare(ADD_SOURCES).bind(json));
  }
  await db.batch(stmts);
  return { ok: true, read: finds.length, expected: s.count, added: finds.length - known, known };
}

const SHARERS = '(SELECT COUNT(*) FROM seen s WHERE s.id = f.id)';

// the newest finds, by when they were found; text stored before names were dropped is never read back out
export async function latest(db, limit) {
  const r = await db.prepare(`SELECT f.id, f.k, f.q, f.found_at, ${SHARERS} AS sharers,
      (SELECT m FROM sources WHERE id = f.id AND m IS NOT NULL LIMIT 1) AS m
    FROM finds f ORDER BY COALESCE(f.found_at, f.added_at) DESC, f.id DESC LIMIT ?1`).bind(limit).all();
  return r.results || [];
}

// one item's find, how many players shared it, and where they got it (ids only: the page names them)
export async function itemFinds(db, id) {
  const find = await db.prepare(`SELECT f.id, f.k, f.q, f.il, f.rq, f.cl, f.sc, f.iv, f.found_at, f.added_at, ${SHARERS} AS sharers
    FROM finds f WHERE f.id = ?1`).bind(id).first();
  if (!find) return null;
  const src = await db.prepare('SELECT t, npc, lv, x, y, m FROM sources WHERE id = ?1 LIMIT 10').bind(id).all();
  const sharers = find.sharers;
  delete find.sharers;
  return { find, sharers, sources: src.results || [] };
}

// how many finds the site holds
export async function total(db) {
  const r = await db.prepare('SELECT COUNT(*) AS n FROM finds').first();
  return r ? r.n : 0;
}
