// Screenshot the three provisioned dashboards from the LIVE Grafana, as rendered, with real data.
//
// WHY BOTH THIS AND THE API PROOF. scripts/capture-observability-evidence.sh section 7 runs every
// panel's own query and records how many series came back -- stronger evidence than an image,
// because it proves the panel CAN query rather than showing what it looked like at one instant. But
// the final-project brief's threshold is that dashboards without real data do not count, and a
// reviewer reading a text file cannot see a dashboard. These are the two halves of the same claim.
//
// PREREQUISITES, and they are deliberately outside this repo's normal toolchain: node and a global
// playwright with a Chromium. Nothing else here needs node, so this is NOT wired into the shell
// capture script -- that one must keep running with bash, curl, python3 and kubectl only, which is
// what lets it run anywhere kubectl does.
//
//   npm i -g playwright                       # chromium comes from /usr/bin/chromium below
//   kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 13000:80 &
//   GRAF_PW=$(kubectl get secret kube-prometheus-stack-grafana -n observability \
//               -o jsonpath='{.data.admin-password}' | base64 -d) \
//     NODE_PATH=$(npm root -g) node scripts/capture-grafana-screenshots.js
//
// Grafana is ClusterIP-only and its admin password is generated into an in-cluster Secret, never
// committed -- hence the port-forward and the env var rather than a URL and a literal.
//
// The output filenames carry a DATE, and dated evidence is never edited afterwards. Change the
// constant below when re-capturing; do not overwrite an older set to "keep it current".

const { chromium } = require('playwright');
const pw = process.env.GRAF_PW;
const DATE = '2026-08-24';

const boards = [
  ['voteball-app',      'application-overview'],
  ['voteball-k8s',      'kubernetes-cluster'],
  ['voteball-delivery', 'jenkins-delivery'],
];
(async () => {
  const b = await chromium.launch({ executablePath: '/usr/bin/chromium' });
  const ctx = await b.newContext({ viewport: { width: 1600, height: 2400 }, deviceScaleFactor: 1 });
  const p = await ctx.newPage();
  await p.goto('http://localhost:13000/login', { waitUntil: 'domcontentloaded' });
  await p.fill('input[name="user"]', 'admin');
  await p.fill('input[name="password"]', pw);
  await p.click('button[type="submit"]');
  await p.waitForURL(u => !u.toString().includes('/login'), { timeout: 30000 }).catch(()=>{});
  for (const [uid, name] of boards) {
    await p.goto(`http://localhost:13000/d/${uid}?from=now-1h&to=now&kiosk`, { waitUntil: 'networkidle' });
    await p.waitForTimeout(8000);
    // Grafana lazy-renders panels as they enter the viewport, so a single jump to the bottom leaves
    // the panels it skipped past unpainted. Walk down in viewport-sized steps instead.
    const h = await p.evaluate(() => document.body.scrollHeight);
    for (let y = 0; y <= h; y += 800) {
      await p.evaluate(_y => window.scrollTo(0, _y), y);
      await p.waitForTimeout(1200);
    }
    await p.evaluate(() => window.scrollTo(0, 0));
    await p.waitForTimeout(3000);
    // Clip to the panels themselves. A tall viewport is what forces every lazy panel to paint, but
    // it also leaves a screen of empty canvas under short dashboards.
    const box = await p.evaluate(() => {
      const els = [...document.querySelectorAll('[data-panelid], .react-grid-item')];
      if (!els.length) return null;
      const b = els.map(e => e.getBoundingClientRect());
      return { bottom: Math.max(...b.map(r => r.bottom)) + window.scrollY + 16 };
    });
    const out = `docs/eks/evidence/${DATE}-grafana-${name}.png`;
    if (box) {
      await p.screenshot({ path: out, clip: { x: 0, y: 0, width: 1600, height: Math.ceil(box.bottom) } });
    } else {
      await p.screenshot({ path: out, fullPage: true });
    }
    console.log('wrote', out);
  }
  await b.close();
})();
