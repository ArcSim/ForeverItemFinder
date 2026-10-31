// GET /api/finds?id=<item>: that item's shared find; GET /api/finds: the newest shared finds and how many there are.
import { latest, itemFinds, total } from '../../lib/store.js';

const json = (body, maxAge) => new Response(JSON.stringify(body), {
  headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': `public, max-age=${maxAge}` },
});

export async function onRequestGet({ request, env }) {
  const url = new URL(request.url);
  const id = Number(url.searchParams.get('id'));
  if (Number.isInteger(id) && id > 0 && id < 10000000) return json(await itemFinds(env.DB, id), 30);
  return json({ total: await total(env.DB), latest: await latest(env.DB, 40) }, 30);
}
