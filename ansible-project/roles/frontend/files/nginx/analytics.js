let analyticsOptionsData = null;
let clubsBreakdown = null;

const DIVERSITY_MIN_VOTES = 10;
let diversityIncludeWorldCup = false;
let diversityView = 'spotlight';

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

// shares: [{party_id, count}, ...] for one club's previous-election votes.
// Returns 1 / sum(share^2) -- "effective number of parties" (Laakso-Taagepera index).
function computeEffectiveParties(previousBreakdown) {
  const total = previousBreakdown.reduce((sum, r) => sum + r.count, 0);
  if (total === 0) return 0;
  const sumSquaredShares = previousBreakdown.reduce((sum, r) => {
    const share = r.count / total;
    return sum + share * share;
  }, 0);
  return 1 / sumSquaredShares;
}

function worldCupLeagueId() {
  const wc = analyticsOptionsData.leagues.find(l => l.name_en === 'World Cup 2026');
  return wc ? wc.id : null;
}

function clubById(clubId) {
  return analyticsOptionsData.clubs.find(c => c.id === clubId);
}

// Every eligible club (>=DIVERSITY_MIN_VOTES previous-election votes, World-Cup-filtered per the
// current toggle state), with its effective-parties score, sorted descending.
function eligibleClubDiversityScores() {
  const wcLeagueId = worldCupLeagueId();
  return clubsBreakdown
    .map(entry => {
      const club = clubById(entry.club_id);
      if (!club) return null;
      const total = entry.previous.reduce((sum, r) => sum + r.count, 0);
      return { club, total, score: computeEffectiveParties(entry.previous) };
    })
    .filter(row => row !== null)
    .filter(row => row.total >= DIVERSITY_MIN_VOTES)
    .filter(row => diversityIncludeWorldCup || row.club.league_id !== wcLeagueId)
    .sort((a, b) => b.score - a.score);
}

function renderDiversityBar(container, row, maxScore) {
  const wrap = document.createElement('div');
  wrap.className = 'standings-row';

  const rank = document.createElement('div');
  rank.className = 'standings-rank';
  rank.textContent = '';
  wrap.appendChild(rank);

  const nameDiv = document.createElement('div');
  nameDiv.className = 'standings-name';
  nameDiv.appendChild(logoEl(row.club, localizedName(row.club)));
  const nameSpan = document.createElement('span');
  nameSpan.textContent = localizedName(row.club);
  nameDiv.appendChild(nameSpan);
  wrap.appendChild(nameDiv);

  const track = document.createElement('div');
  track.className = 'standings-track';
  const fill = document.createElement('div');
  fill.className = 'standings-fill';
  fill.style.width = `${Math.round((row.score / maxScore) * 100)}%`;
  track.appendChild(fill);
  wrap.appendChild(track);

  const stat = document.createElement('div');
  stat.className = 'standings-stat';
  stat.textContent = t('analyticsEffectiveParties').replace('{n}', row.score.toFixed(1));
  wrap.appendChild(stat);

  container.appendChild(wrap);
}

function renderDiversitySpotlight(rows) {
  const container = document.createElement('div');
  container.className = 'diversity-spotlight-split';

  const mostMixed = document.createElement('div');
  const mostMixedHeading = document.createElement('div');
  mostMixedHeading.className = 'diversity-spotlight-heading most-mixed';
  mostMixedHeading.textContent = t('analyticsMostMixed');
  mostMixed.appendChild(mostMixedHeading);
  const mostMixedList = document.createElement('div');
  mostMixedList.className = 'standings';
  mostMixed.appendChild(mostMixedList);

  const mostOneSided = document.createElement('div');
  const mostOneSidedHeading = document.createElement('div');
  mostOneSidedHeading.className = 'diversity-spotlight-heading most-one-sided';
  mostOneSidedHeading.textContent = t('analyticsMostOneSided');
  mostOneSided.appendChild(mostOneSidedHeading);
  const mostOneSidedList = document.createElement('div');
  mostOneSidedList.className = 'standings';
  mostOneSided.appendChild(mostOneSidedList);

  const maxScore = rows.length ? rows[0].score : 1;
  rows.slice(0, 5).forEach(row => renderDiversityBar(mostMixedList, row, maxScore));
  rows.slice(-5).reverse().forEach(row => renderDiversityBar(mostOneSidedList, row, maxScore));

  container.appendChild(mostMixed);
  container.appendChild(mostOneSided);
  return container;
}

function renderDiversityFullRanking(rows) {
  const container = document.createElement('div');
  container.className = 'standings';
  const maxScore = rows.length ? rows[0].score : 1;
  rows.forEach(row => renderDiversityBar(container, row, maxScore));
  return container;
}

function renderDiversityTab() {
  const tab = document.getElementById('diversity-tab');
  tab.innerHTML = '';

  const controls = document.createElement('div');
  controls.className = 'diversity-controls';

  const viewToggle = document.createElement('div');
  viewToggle.className = 'pill-group';
  ['spotlight', 'full'].forEach(view => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.setAttribute('aria-pressed', String(view === diversityView));
    btn.textContent = view === 'spotlight' ? t('analyticsSpotlight') : t('analyticsFullRanking');
    btn.addEventListener('click', () => { diversityView = view; renderDiversityTab(); });
    viewToggle.appendChild(btn);
  });
  controls.appendChild(viewToggle);

  const wcLabel = document.createElement('label');
  wcLabel.className = 'diversity-worldcup-label';
  const wcCheckbox = document.createElement('input');
  wcCheckbox.type = 'checkbox';
  wcCheckbox.checked = diversityIncludeWorldCup;
  wcCheckbox.addEventListener('change', () => {
    diversityIncludeWorldCup = wcCheckbox.checked;
    renderDiversityTab();
  });
  wcLabel.appendChild(wcCheckbox);
  const wcText = document.createElement('span');
  wcText.textContent = t('analyticsIncludeWorldCup');
  wcLabel.appendChild(wcText);
  controls.appendChild(wcLabel);

  tab.appendChild(controls);

  const rows = eligibleClubDiversityScores();
  if (!rows.length) {
    const empty = document.createElement('p');
    empty.className = 'note';
    empty.textContent = t('analyticsTooFewVotes');
    tab.appendChild(empty);
    return;
  }

  tab.appendChild(diversityView === 'spotlight' ? renderDiversitySpotlight(rows) : renderDiversityFullRanking(rows));
}

async function initAnalytics() {
  try {
    analyticsOptionsData = await fetchJSON('/api/options');
    clubsBreakdown = await fetchJSON('/api/results/clubs-breakdown');
  } catch (err) {
    analyticsShowError('diversity-tab');
    return;
  }
  renderDiversityTab();
}

document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
  renderDiversityTab();
});

initAnalytics();
