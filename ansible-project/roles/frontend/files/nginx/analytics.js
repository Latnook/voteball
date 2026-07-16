let analyticsOptionsData = null;
let clubsBreakdown = null;

const DIVERSITY_MIN_VOTES = 10;
const LEAN_MIN_VOTES = 10;
const SWITCH_TAKEAWAY_THRESHOLD_POINTS = 5;
const SWITCH_STATUSES = ['stayed', 'hedging', 'switched', 'new_voter', 'undecided'];
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

function renderDiversityBar(container, row, maxScore, rankNumber) {
  const wrap = document.createElement('div');
  wrap.className = 'standings-row';

  const rank = document.createElement('div');
  rank.className = 'standings-rank';
  rank.textContent = String(rankNumber);
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

// Builds one spotlight column: a heading plus a `.standings` list container.
function buildDiversityColumn(headingClass, headingText) {
  const column = document.createElement('div');
  const heading = document.createElement('div');
  heading.className = `diversity-spotlight-heading ${headingClass}`;
  heading.textContent = headingText;
  column.appendChild(heading);
  const list = document.createElement('div');
  list.className = 'standings';
  column.appendChild(list);
  return { column, list };
}

function renderDiversitySpotlight(rows) {
  const container = document.createElement('div');
  container.className = 'diversity-spotlight-split';

  const { column: mostMixed, list: mostMixedList } = buildDiversityColumn('most-mixed', t('analyticsMostMixed'));
  const { column: mostOneSided, list: mostOneSidedList } = buildDiversityColumn('most-one-sided', t('analyticsMostOneSided'));

  // Cap each column so they never overlap when fewer than 10 clubs are eligible.
  // (spotlightCount can be 0 with <2 rows; guard the bottom slice since
  // Array.prototype.slice(-0) is equivalent to slice(0), not an empty slice.)
  const spotlightCount = Math.min(5, Math.floor(rows.length / 2));
  const maxScore = rows.length ? rows[0].score : 1;
  rows.slice(0, spotlightCount).forEach((row, idx) => renderDiversityBar(mostMixedList, row, maxScore, idx + 1));
  const bottomRows = spotlightCount > 0 ? rows.slice(-spotlightCount).reverse() : [];
  bottomRows.forEach((row, idx) => renderDiversityBar(mostOneSidedList, row, maxScore, idx + 1));

  container.appendChild(mostMixed);
  container.appendChild(mostOneSided);
  return container;
}

function renderDiversityFullRanking(rows) {
  const container = document.createElement('div');
  container.className = 'standings';
  const maxScore = rows.length ? rows[0].score : 1;
  rows.forEach((row, idx) => renderDiversityBar(container, row, maxScore, idx + 1));
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
    renderLeanTab();
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

function partyById(partyId, list) {
  return analyticsOptionsData[list].find(p => p.id === partyId);
}

// Weighted average of a numeric axis (economic/security) over a club's previous-election votes,
// skipping parties with a null value on that axis (both from the numerator and the denominator) --
// see design spec Decision 8.
function weightedAxisAverage(previousBreakdown, axis) {
  let weightedSum = 0;
  let weightTotal = 0;
  previousBreakdown.forEach(r => {
    const party = partyById(r.party_id, 'previous_parties');
    if (!party || party[axis] === null || party[axis] === undefined) return;
    weightedSum += party[axis] * r.count;
    weightTotal += r.count;
  });
  return weightTotal > 0 ? weightedSum / weightTotal : null;
}

function compositionPercentages(previousBreakdown, field, categories) {
  const totals = {};
  categories.forEach(c => { totals[c] = 0; });
  let total = 0;
  previousBreakdown.forEach(r => {
    const party = partyById(r.party_id, 'previous_parties');
    if (!party || !party[field] || !(party[field] in totals)) return;
    totals[party[field]] += r.count;
    total += r.count;
  });
  if (total === 0) return null;
  const pct = {};
  categories.forEach(c => { pct[c] = Math.round((totals[c] / total) * 100); });
  return pct;
}

function eligibleClubLeanRows() {
  const wcLeagueId = worldCupLeagueId();
  return clubsBreakdown
    .map(entry => {
      const club = clubById(entry.club_id);
      if (!club) return null;
      const total = entry.previous.reduce((sum, r) => sum + r.count, 0);
      const economic = weightedAxisAverage(entry.previous, 'economic');
      return { club, total, economic, previous: entry.previous };
    })
    .filter(row => row !== null && row.total >= LEAN_MIN_VOTES && row.economic !== null)
    .filter(row => diversityIncludeWorldCup || row.club.league_id !== wcLeagueId);
}

function renderLeanDetail(container, label, previousBreakdown) {
  container.innerHTML = '';
  const heading = document.createElement('div');
  heading.className = 'scoreboard-title';
  heading.textContent = label;
  container.appendChild(heading);

  const security = weightedAxisAverage(previousBreakdown, 'security');
  const securityRow = document.createElement('div');
  securityRow.className = 'lean-detail-row';
  const securityLabel = document.createElement('span');
  securityLabel.textContent = t('analyticsSecurityLabel');
  securityRow.appendChild(securityLabel);
  const securityValue = document.createElement('span');
  securityValue.textContent = security === null
    ? t('analyticsNoStatedPosition')
    : `${security.toFixed(1)} (${security < 0 ? t('analyticsSecurityDovish') : t('analyticsSecurityHawkish')})`;
  securityRow.appendChild(securityValue);
  container.appendChild(securityRow);

  const blocPct = compositionPercentages(previousBreakdown, 'bloc', ['bibi', 'opposition', 'unaligned']);
  const blocRow = document.createElement('div');
  blocRow.className = 'lean-detail-row';
  const blocLabel = document.createElement('span');
  blocLabel.textContent = t('analyticsBlocLabel');
  blocRow.appendChild(blocLabel);
  const blocValue = document.createElement('span');
  blocValue.textContent = blocPct
    ? `${blocPct.bibi}% ${t('analyticsBlocBibi')} · ${blocPct.opposition}% ${t('analyticsBlocOpposition')} · ${blocPct.unaligned}% ${t('analyticsBlocUnaligned')}`
    : t('analyticsNoStatedPosition');
  blocRow.appendChild(blocValue);
  container.appendChild(blocRow);

  const sectorCategories = ['secular', 'traditional', 'religious_zionist', 'haredi', 'arab'];
  const sectorPct = compositionPercentages(previousBreakdown, 'sector', sectorCategories);
  const sectorRow = document.createElement('div');
  sectorRow.className = 'lean-detail-row';
  const sectorLabel = document.createElement('span');
  sectorLabel.textContent = t('analyticsSectorLabel');
  sectorRow.appendChild(sectorLabel);
  const sectorValue = document.createElement('span');
  const sectorKeyMap = {
    secular: 'analyticsSectorSecular', traditional: 'analyticsSectorTraditional',
    religious_zionist: 'analyticsSectorReligiousZionist', haredi: 'analyticsSectorHaredi', arab: 'analyticsSectorArab',
  };
  sectorValue.textContent = sectorPct
    ? sectorCategories.filter(c => sectorPct[c] > 0).map(c => `${sectorPct[c]}% ${t(sectorKeyMap[c])}`).join(' · ')
    : t('analyticsNoStatedPosition');
  sectorRow.appendChild(sectorValue);
  container.appendChild(sectorRow);
}

function nationalPreviousBreakdown() {
  const totals = {};
  clubsBreakdown.forEach(entry => {
    entry.previous.forEach(r => {
      totals[r.party_id] = (totals[r.party_id] || 0) + r.count;
    });
  });
  return Object.entries(totals).map(([partyId, count]) => ({ party_id: Number(partyId), count }));
}

function renderLeanTab() {
  const tab = document.getElementById('lean-tab');
  tab.innerHTML = '';

  const rows = eligibleClubLeanRows();
  if (!rows.length) {
    const empty = document.createElement('p');
    empty.className = 'note';
    empty.textContent = t('analyticsTooFewVotes');
    tab.appendChild(empty);
    return;
  }

  const strip = document.createElement('div');
  strip.className = 'lean-strip';
  const detail = document.createElement('div');
  detail.className = 'card';

  function selectClub(row, badge) {
    strip.querySelectorAll('.lean-badge').forEach(b => b.setAttribute('aria-pressed', 'false'));
    if (badge) badge.setAttribute('aria-pressed', 'true');
    renderLeanDetail(detail, row ? localizedName(row.club) : t('analyticsNational'), row ? row.previous : nationalPreviousBreakdown());
  }

  rows.forEach(row => {
    const badge = document.createElement('button');
    badge.type = 'button';
    badge.className = 'lean-badge';
    badge.setAttribute('aria-pressed', 'false');
    badge.style.left = `${((row.economic + 3) / 6) * 100}%`;
    badge.textContent = localizedName(row.club);
    badge.addEventListener('click', () => selectClub(row, badge));
    strip.appendChild(badge);
  });

  const axisLabels = document.createElement('div');
  axisLabels.className = 'lean-axis-labels';
  const leftLabel = document.createElement('span');
  leftLabel.textContent = `← ${t('analyticsAxisLeft')}`;
  const rightLabel = document.createElement('span');
  rightLabel.textContent = `${t('analyticsAxisRight')} →`;
  axisLabels.appendChild(leftLabel);
  axisLabels.appendChild(rightLabel);

  tab.appendChild(strip);
  tab.appendChild(axisLabels);
  tab.appendChild(detail);

  selectClub(null, null);
}

function switchStatusLabel(status) {
  const keyMap = {
    stayed: 'analyticsStatusStayed', hedging: 'analyticsStatusHedging', switched: 'analyticsStatusSwitched',
    new_voter: 'analyticsStatusNewVoter', undecided: 'analyticsStatusUndecided',
  };
  return t(keyMap[status]);
}

function switchBreakdownToShares(breakdown) {
  const total = breakdown.reduce((sum, r) => sum + r.count, 0);
  const counts = {};
  SWITCH_STATUSES.forEach(s => { counts[s] = 0; });
  breakdown.forEach(r => { if (r.status in counts) counts[r.status] = r.count; });
  const shares = {};
  SWITCH_STATUSES.forEach(s => { shares[s] = total > 0 ? (counts[s] / total) * 100 : 0; });
  return { shares, total };
}

function renderSwitchBar(container, label, breakdown, isBaseline) {
  const labelEl = document.createElement('div');
  labelEl.className = 'switch-bar-label';
  labelEl.textContent = label;
  container.appendChild(labelEl);

  const { shares } = switchBreakdownToShares(breakdown);
  const bar = document.createElement('div');
  bar.className = isBaseline ? 'switch-bar is-baseline' : 'switch-bar';
  SWITCH_STATUSES.forEach(status => {
    if (shares[status] <= 0) return;
    const segment = document.createElement('div');
    segment.className = `switch-segment status-${status}`;
    segment.style.width = `${shares[status]}%`;
    segment.textContent = shares[status] >= 12 ? `${switchStatusLabel(status)} ${Math.round(shares[status])}%` : '';
    bar.appendChild(segment);
  });
  container.appendChild(bar);
  return shares;
}

function renderSwitchTakeaway(container, scopeLabel, scopeShares, nationalShares) {
  const p = document.createElement('p');
  p.className = 'note';
  const delta = scopeShares.stayed - nationalShares.stayed;
  let key = 'analyticsTakeawayAboutAverage';
  if (delta > SWITCH_TAKEAWAY_THRESHOLD_POINTS) key = 'analyticsTakeawayMoreLoyal';
  else if (delta < -SWITCH_TAKEAWAY_THRESHOLD_POINTS) key = 'analyticsTakeawayLessLoyal';
  p.textContent = t(key).replace('{who}', scopeLabel);
  container.appendChild(p);
}

async function loadSwitchingScope(leagueId, clubId, scopeLabel) {
  const barsContainer = document.getElementById('switching-bars');
  const takeawayContainer = document.getElementById('switching-takeaway');
  barsContainer.innerHTML = '';
  takeawayContainer.innerHTML = '';

  try {
    const query = clubId ? `club_id=${clubId}` : (leagueId ? `league_id=${leagueId}` : '');
    const [scopeData, nationalData] = await Promise.all([
      fetchJSON(`/api/results/switch${query ? '?' + query : ''}`),
      fetchJSON('/api/results/switch'),
    ]);
    const scopeShares = renderSwitchBar(barsContainer, scopeLabel, scopeData.breakdown, false);
    const nationalShares = renderSwitchBar(barsContainer, t('analyticsBaselineLabel'), nationalData.breakdown, true);
    if (leagueId || clubId) {
      renderSwitchTakeaway(takeawayContainer, scopeLabel, scopeShares, nationalShares);
    }
  } catch (err) {
    analyticsShowError('switching-bars');
  }
}

function renderSwitchingScopePicker() {
  const picker = document.getElementById('switching-scope-picker');
  picker.innerHTML = '';

  const nationalOption = document.createElement('option');
  nationalOption.value = '';
  nationalOption.textContent = t('analyticsNational');
  picker.appendChild(nationalOption);

  analyticsOptionsData.leagues.forEach(league => {
    const opt = document.createElement('option');
    opt.value = `league:${league.id}`;
    opt.textContent = localizedName(league);
    picker.appendChild(opt);
  });
  analyticsOptionsData.clubs.forEach(club => {
    const opt = document.createElement('option');
    opt.value = `club:${club.id}`;
    opt.textContent = localizedName(club);
    picker.appendChild(opt);
  });
}

function renderSwitchingTab() {
  const tab = document.getElementById('switching-tab');
  tab.innerHTML = '';

  const field = document.createElement('label');
  field.className = 'field';
  const labelSpan = document.createElement('span');
  labelSpan.textContent = t('analyticsScopeLabel');
  field.appendChild(labelSpan);
  const picker = document.createElement('select');
  picker.id = 'switching-scope-picker';
  field.appendChild(picker);
  tab.appendChild(field);

  const barsContainer = document.createElement('div');
  barsContainer.id = 'switching-bars';
  tab.appendChild(barsContainer);

  const takeawayContainer = document.createElement('p');
  takeawayContainer.id = 'switching-takeaway';
  takeawayContainer.className = 'note';
  tab.appendChild(takeawayContainer);

  renderSwitchingScopePicker();
  picker.addEventListener('change', () => {
    const [kind, id] = (picker.value || '').split(':');
    if (!kind) {
      loadSwitchingScope(null, null, t('analyticsNational'));
    } else if (kind === 'league') {
      const league = analyticsOptionsData.leagues.find(l => l.id === Number(id));
      loadSwitchingScope(Number(id), null, localizedName(league));
    } else {
      const club = analyticsOptionsData.clubs.find(c => c.id === Number(id));
      loadSwitchingScope(null, Number(id), localizedName(club));
    }
  });
  loadSwitchingScope(null, null, t('analyticsNational'));
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
  renderLeanTab();
  renderSwitchingTab();
}

document.addEventListener('voteball:langchange', () => {
  if (!analyticsOptionsData) return;
  renderDiversityTab();
  renderLeanTab();
  renderSwitchingTab();
});

initAnalytics();
