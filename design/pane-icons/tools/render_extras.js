// Renders the extras: Pane Dev's blueprint layer and preview, and the figure PNGs.
// Run from the repo root: node design/pane-icons/tools/render_extras.js design/pane-icons
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
(async () => {
  const dir = process.argv[2];
  const jobs = [
    ['pane-dev.icon/Assets/blueprint.svg', 'pane-dev.icon/Assets/blueprint.png', 1024],
    ['previews/pane-dev.svg', 'previews/pane-dev.png', 1024],
    ...['pane-mark', 'pane-mark-back', 'pane-mark-front', 'pane-mark-flat']
      .map(n => [`figure/${n}.svg`, `figure/${n}.png`, 1254]),
  ];
  const b = await chromium.launch();
  for (const [src, dst, size] of jobs) {
    const p = await b.newPage({ viewport: { width: size, height: size } });
    await p.setContent(`<html><body style="margin:0;background:transparent">${fs.readFileSync(path.join(dir, src), 'utf8')}</body></html>`);
    await p.locator('svg').screenshot({ path: path.join(dir, dst), omitBackground: true });
    await p.close();
  }
  // A check sheet: the Dev icon, and the figure on the welcome page's grey.
  const p = await b.newPage({ viewport: { width: 1200, height: 520 } });
  const pic = f => `data:image/png;base64,${fs.readFileSync(path.join(dir, f)).toString('base64')}`;
  await p.setContent(`<body style="margin:0;display:flex;gap:24px;padding:24px;background:#F4F4F6;font:13px system-ui;align-items:center">
    <img src="${pic('previews/pane-dev.png')}" width="300">
    <img src="${pic('figure/pane-mark.png')}" width="300">
    <img src="${pic('figure/pane-mark-flat.png')}" width="180">
    <div style="display:flex;flex-direction:column;gap:8px"><img src="${pic('figure/pane-mark-back.png')}" width="150" style="background:#ddd"><img src="${pic('figure/pane-mark-front.png')}" width="150" style="background:#ddd"></div></body>`);
  await p.screenshot({ path: path.join(dir, 'extras-sheet.png') });
  await b.close();
})();
