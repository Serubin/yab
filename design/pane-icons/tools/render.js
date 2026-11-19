const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
(async () => {
  const dir = process.argv[2];
  const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 1024, height: 1024 } });
  const files = fs.readdirSync(path.join(dir, 'previews')).filter(f => f.endsWith('.svg')).sort();
  for (const f of files) {
    const svg = fs.readFileSync(path.join(dir, 'previews', f), 'utf8');
    await p.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
    await p.locator('svg').screenshot({ path: path.join(dir, 'previews', f.replace('.svg', '.png')), omitBackground: true });
  }
  const cells = files.map(f => `<figure style="margin:0;text-align:center;font:13px system-ui">${fs.readFileSync(path.join(dir,'previews',f),'utf8').replace('width="1024" height="1024"','width="150" height="150"')}<figcaption>${f.replace('.svg','')}</figcaption></figure>`).join('');
  await p.setViewportSize({ width: 1100, height: 600 });
  await p.setContent(`<body style="margin:0;padding:20px;background:#e8ecf2;display:grid;grid-template-columns:repeat(6,1fr);gap:16px">${cells}</body>`);
  await p.screenshot({ path: path.join(dir, 'contact-sheet.png'), fullPage: true });
  await b.close();
})();
