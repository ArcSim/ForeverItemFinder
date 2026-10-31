// Pulls the map art of every zone the site pins (meta.json art) from the CDN through wow.tools.local: each zone's base
// tiles and explored overlays, then compose_maps.py lays them into public/maps/<map>.jpg as the addon draws the map.
// usage: node site/fetch_maps.js   (run build_data.lua first; WoW may stay open, the files come from the CDN)
const fs = require('fs');
const path = require('path');
const { spawn, execFileSync } = require('child_process');
const WTL_DIR = 'E:/WoWDev/tools/wow.tools.local/app';
const TABLES = 'E:/WoWDev/projects/ArcDiscoveries/datamine/forever_maps/1.60.1.70685';
const CACHE = 'E:/WoWDev/projects/ArcDiscoveries/datamine/map_art';
const SITE = __dirname;

async function waitFor(url, s) {
	for (let i = 0; i < s; i++) {
		try { if ((await fetch(url)).ok) return true; } catch (e) {}
		await new Promise(r => setTimeout(r, 1000));
	}
	return false;
}
const csvRows = text => {
	const lines = text.split(/\r?\n/).filter(Boolean);
	const head = lines[0].split(',');
	return lines.slice(1).map(l => Object.fromEntries(l.split(',').map((v, i) => [head[i], v])));
};

(async () => {
	const meta = JSON.parse(fs.readFileSync(path.join(SITE, 'public/data/meta.json'), 'utf8'));
	const maps = Object.keys(meta.art || {}).map(Number);
	if (!maps.length) throw new Error('meta.json lists no maps: run build_data.lua first');
	const xArt = csvRows(fs.readFileSync(path.join(TABLES, 'UiMapXMapArt.csv'), 'utf8'));
	const artOf = new Map(xArt.filter(r => r.PhaseID === '0').map(r => [+r.UiMapID, +r.UiMapArtID]));
	const ovText = fs.readFileSync(path.join(SITE, '../Data/MapOverlays.lua'), 'utf8');
	const wtl = spawn(path.join(WTL_DIR, 'wow.tools.local.exe'), ['-wowFolder', '', '-wowProduct', 'wowf', '-region', 'us'], { cwd: WTL_DIR, stdio: 'ignore' });
	try {
		if (!(await waitFor('http://localhost:5000/', 300))) throw new Error('wow.tools.local did not start');
		const { currentBuild } = require('E:/WoWDev/projects/ArcDiscoveries/datamine/scripts/latest.js');
		const version = await currentBuild('http://us.patch.battle.net:1119/wowf/versions');
		const res = await fetch(`http://localhost:5000/dbc/export/?name=UiMapArtTile&build=${version}`);
		if (!res.ok) throw new Error('UiMapArtTile export: HTTP ' + res.status);
		const tiles = csvRows(Buffer.from(await res.arrayBuffer()).toString('utf8'));
		const out = {};
		const want = new Set();
		for (const m of maps) {
			const art = artOf.get(m);
			const base = tiles.filter(t => +t.UiMapArtID === art && +t.LayerIndex === 0)
				.map(t => ({ row: +t.RowIndex, col: +t.ColIndex, file: +t.FileDataID }));
			if (!base.length) throw new Error(`map ${m} has no base tiles`);
			const ov = (new RegExp(`\\[${m}\\] = "([^"]*)"`).exec(ovText) || [])[1] || '';
			const overlays = ov.split(';').filter(Boolean).map(s => {
				const f = s.split(',').map(Number);
				return { w: f[0], h: f[1], x: f[2], y: f[3], files: f.slice(4) };
			});
			out[m] = { art, base, overlays };
			for (const t of base) want.add(t.file);
			for (const o of overlays) for (const f of o.files) want.add(f);
		}
		fs.mkdirSync(path.join(CACHE, 'blp'), { recursive: true });
		let got = 0;
		const failed = [];
		for (const f of want) {
			const p = path.join(CACHE, 'blp', f + '.blp');
			if (fs.existsSync(p)) { got++; continue; }
			const r = await fetch(`http://localhost:5000/casc/fdid?filedataid=${f}`);
			if (!r.ok) { failed.push(f); continue; }
			fs.writeFileSync(p, Buffer.from(await r.arrayBuffer()));
			got++;
		}
		fs.writeFileSync(path.join(CACHE, 'tiles.json'), JSON.stringify(out, null, 1));
		console.log(`${maps.length} maps: ${got} files${failed.length ? ', missing ' + failed.join(' ') : ''}`);
		if (failed.length) throw new Error('some map files could not be read');
	} finally {
		wtl.kill();
	}
	fs.mkdirSync(path.join(SITE, 'public/maps'), { recursive: true });
	execFileSync('python', ['-I', path.join(SITE, 'compose_maps.py'), CACHE, path.join(SITE, 'public/maps')], { stdio: 'inherit' });
})().catch(e => { console.error(e.message); process.exit(1); });
