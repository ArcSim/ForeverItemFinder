// Reads the string the addon's "Share your finds" button gives (Proto.lua EncodeShare / DecodeShare, same rules):
// "FIFS^1^<install>^<count>^" then one find message per find, all joined by "^". Each message is fields joined by
// "~" with a checksum last; anything that fails its checks is skipped.
export const SHARE = 'FIFS';
export const VERSION = 1;
const MAX = 250;
const enc = new TextEncoder();

// the addon sums the message's bytes, so this does too
export function checksum(s) {
  const b = enc.encode(s);
  let sum = 0;
  for (let i = 0; i < b.length; i++) sum = (sum + b[i] * (((i + 1) % 13) + 1)) % 65536;
  return sum.toString(16).padStart(4, '0');
}

function num(s, lo, hi) {
  if (typeof s !== 'string' || !/^-?\d+$/.test(s)) return undefined;
  const n = Number(s);
  return n >= lo && n <= hi ? n : undefined;
}

export function decodeFind(msg) {
  if (typeof msg !== 'string') return null;
  const bytes = enc.encode(msg).length;
  if (bytes < 6 || bytes > MAX) return null;
  const m = msg.match(/^([\s\S]*)~([0-9a-fA-F]{4})$/);
  if (!m || checksum(m[1]) !== m[2]) return null;
  const f = m[1].split('~');
  if (f[0] !== 'F' || f.length !== 23 || num(f[1], 0, 99) !== VERSION) return null;
  const id = num(f[2], 1, 9999999);
  const kind = f[3];
  if (id === undefined || (kind !== 'n' && kind !== 'c')) return null;
  const info = {
    id, kind,
    q: num(f[4], 0, 8), ilvl: num(f[5], 0, 2000), req: num(f[6], 0, 200),
    cls: num(f[7], -1, 30), sub: num(f[8], -1, 40), inv: num(f[9], -1, 40), ac: num(f[10], -1, 2147483647),
    fp: f[11] !== '' ? f[11] : undefined,
    by: f[20] !== '' ? f[20] : undefined,
    at: num(f[21], 1000000000, 4000000000),
  };
  const st = f[12];
  if (st !== '-') {
    if (st.length !== 1 || !'lrvqcox'.includes(st)) return null;
    info.src = {
      t: st, n: f[13] !== '' ? f[13] : undefined, npc: num(f[14], 1, 9999999), lv: num(f[15], -1, 200),
      z: f[16] !== '' ? f[16] : undefined, sz: f[17] !== '' ? f[17] : undefined,
      x: num(f[18], 0, 1000), y: num(f[19], 0, 1000), m: num(f[22], 1, 999999),
    };
  }
  return info;
}

// { install, finds, count } or null when the text is no share string
export function decodeShare(text) {
  if (typeof text !== 'string') return null;
  const parts = text.trim().split('^');
  if (parts[0] !== SHARE || num(parts[1], 0, 99) !== VERSION) return null;
  const count = num(parts[3], 0, 100000);
  if (count === undefined || !parts[2]) return null;
  const finds = [];
  for (let i = 4; i < parts.length; i++) {
    const info = decodeFind(parts[i]);
    if (info) finds.push(info);
  }
  return { install: parts[2], finds, count };
}
