// POST /api/share: the body is a share string from the addon. Players are told apart by an anonymous id in the string;
// the address is kept only as a salted hash, to slow down one address sharing over and over.
import { share, MAX_TEXT } from '../../lib/store.js';

const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
});

async function hash(text) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(d)].slice(0, 12).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function onRequestPost({ request, env }) {
  const length = Number(request.headers.get('content-length') || 0);
  if (length > MAX_TEXT * 4) return json({ ok: false, error: 'That is far longer than a share string.' }, 413);
  const text = await request.text();
  const key = await hash((env.SALT || '') + '|' + (request.headers.get('CF-Connecting-IP') || ''));
  const r = await share(env.DB, text, key, Math.floor(Date.now() / 1000));
  return json(r, r.ok ? 200 : r.status);
}
