let analyticsOptionsData = null;
let clubsBreakdown = null;

function analyticsShowError(containerId) {
  const el = document.getElementById(containerId);
  if (!el) return;
  el.innerHTML = '';
  const p = document.createElement('p');
  p.className = 'error';
  p.textContent = t('analyticsErrorLoad');
  el.appendChild(p);
}

function switchAnalyticsTab(tabName) {
  document.querySelectorAll('#analytics-tabs button[data-tab]').forEach(btn => {
    btn.setAttribute('aria-pressed', String(btn.dataset.tab === tabName));
  });
  document.getElementById('diversity-tab').hidden = tabName !== 'diversity';
  document.getElementById('lean-tab').hidden = tabName !== 'lean';
  document.getElementById('switching-tab').hidden = tabName !== 'switching';
}

document.getElementById('analytics-tabs').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-tab]');
  if (!btn) return;
  switchAnalyticsTab(btn.dataset.tab);
});

async function initAnalytics() {
  try {
    analyticsOptionsData = await fetchJSON('/api/options');
    clubsBreakdown = await fetchJSON('/api/results/clubs-breakdown');
  } catch (err) {
    analyticsShowError('diversity-tab');
    return;
  }
}

document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
});

initAnalytics();
