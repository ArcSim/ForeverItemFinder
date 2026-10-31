// Fetches every item icon the site's index names from wow.tools.local (running on the Forever install, WoW closed:
// Start-WTL-Forever.cmd) as PNG into public/icons/<file id>.png. Icons already there are kept.
// usage: node fetch_icons.js
const fs = require('fs');
const path = require('path');
const OUT = path.join(__dirname, 'public', 'icons');
const WTL = 'http://localhost:5000/casc/blp2png?filedataid=';

(async () => {
  const index = JSON.parse(fs.readFileSync(path.join(__dirname, 'public', 'data', 'index.json'), 'utf8'));
  const ids = [...new Set(index.map((r) => r[12]).filter(Boolean))];
  fs.mkdirSync(OUT, { recursive: true });
  const todo = ids.filter((id) => !fs.existsSync(path.join(OUT, id + '.png')));
  let got = 0, failed = [], bytes = 0;
  const worker = async () => {
    while (todo.length) {
      const id = todo.pop();
      try {
        const r = await fetch(WTL + id);
        const buf = Buffer.from(await r.arrayBuffer());
        // a PNG starts with its signature; anything else is the server's error page
        if (r.ok && buf.length > 8 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
          fs.writeFileSync(path.join(OUT, id + '.png'), buf);
          got++;
          bytes += buf.length;
        } else failed.push(id);
      } catch {
        failed.push(id);
      }
    }
  };
  await Promise.all(Array.from({ length: 6 }, worker));
  console.log(`icons: ${ids.length} named, ${got} fetched now (${Math.round(bytes / 1024)} KB), ${failed.length} failed${failed.length ? ': ' + failed.slice(0, 12).join(', ') : ''}`);
})();
