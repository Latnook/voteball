let analyticsOptionsData = null;
let clubsBreakdown = null;
let nationalPreviousData = null;

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

// Weighted average of a numeric axis (economic/security/religiosity) over a club's previous-election votes,
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

// The three numeric ideology axes, in card order. Each carries the i18n keys for its own label and
// for the words at its negative and positive poles -- they are NOT the same words per axis
// (left/right, dovish/hawkish, separationist/clerical), which is why this is a table and not a loop
// over bare column names.
const LEAN_AXES = [
  { key: 'economic', labelKey: 'analyticsEconomicLabel', shortKey: 'analyticsAxisEconomicShort',
    negKey: 'analyticsAxisLeft', posKey: 'analyticsAxisRight' },
  { key: 'security', labelKey: 'analyticsSecurityLabel', shortKey: 'analyticsAxisSecurityShort',
    negKey: 'analyticsSecurityDovish', posKey: 'analyticsSecurityHawkish' },
  { key: 'religiosity', labelKey: 'analyticsReligiosityLabel', shortKey: 'analyticsAxisReligiosityShort',
    negKey: 'analyticsReligiositySeparationist', posKey: 'analyticsReligiosityClerical' },
];

let leanAxis = 'economic';

function leanAxisConfig(key) {
  return LEAN_AXES.find(a => a.key === key) || LEAN_AXES[0];
}

// Every club clearing the vote threshold, carrying its average on all three axes. Not filtered by
// axis: the strip needs the full set so a dot can persist (and slide) even across an axis where it
// briefly has no value.
function allLeanClubRows() {
  const wcLeagueId = worldCupLeagueId();
  return clubsBreakdown
    .map(entry => {
      const club = clubById(entry.club_id);
      if (!club) return null;
      const total = entry.previous.reduce((sum, r) => sum + r.count, 0);
      const values = {};
      LEAN_AXES.forEach(a => { values[a.key] = weightedAxisAverage(entry.previous, a.key); });
      return { club, total, values, previous: entry.previous };
    })
    .filter(row => row !== null && row.total >= LEAN_MIN_VOTES)
    .filter(row => diversityIncludeWorldCup || row.club.league_id !== wcLeagueId);
}

// Positions for one axis. Dots on near-identical averages would overlap exactly, so walk them left
// to right and drop each into the first lane whose previous dot is far enough away, else the lane
// whose last dot is furthest left. Clubs with no value on this axis are absent from the result --
// a fanbase voting only for parties that are NULL on that axis has no position on it.
function layoutLeanDots(rows, axisKey) {
  const LANES = 3;
  const MIN_GAP_PCT = 7;
  const laneLastX = new Array(LANES).fill(-Infinity);
  const placed = new Map();
  rows
    .filter(row => row.values[axisKey] !== null)
    .sort((a, b) => a.values[axisKey] - b.values[axisKey])
    .forEach(row => {
      const x = ((row.values[axisKey] + 3) / 6) * 100;
      let lane = 0;
      let fallback = 0;
      for (let i = 0; i < LANES; i++) {
        if (x - laneLastX[i] >= MIN_GAP_PCT) { lane = i; break; }
        if (laneLastX[i] < laneLastX[fallback]) fallback = i;
        if (i === LANES - 1) lane = fallback;
      }
      laneLastX[lane] = x;
      placed.set(row.club.id, { x, lane });
    });
  return placed;
}

function renderLeanDetail(container, label, previousBreakdown) {
  container.innerHTML = '';
  const heading = document.createElement('div');
  heading.className = 'scoreboard-title';
  heading.textContent = label;
  container.appendChild(heading);

  // All three numeric axes, including the one the strip is currently positioning by -- the strip
  // shows only relative order, so the actual figure still belongs here.
  LEAN_AXES.forEach(axis => {
    const value = weightedAxisAverage(previousBreakdown, axis.key);
    const row = document.createElement('div');
    row.className = 'lean-detail-row';
    const rowLabel = document.createElement('span');
    rowLabel.textContent = t(axis.labelKey);
    row.appendChild(rowLabel);
    const rowValue = document.createElement('span');
    rowValue.textContent = value === null
      ? t('analyticsNoStatedPosition')
      : `${value.toFixed(1)} (${value < 0 ? t(axis.negKey) : t(axis.posKey)})`;
    row.appendChild(rowValue);
    container.appendChild(row);
  });

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

// National previous-party breakdown for the Lean tab's default view. Deliberately NOT a sum over
// clubsBreakdown (rollup_previous WHERE club_id IS NOT NULL): that would double-count multi-club
// ballots (two club-scope rows sharing one previous_party_id) and silently drop league-only voters
// (club_id IS NULL rows excluded by that filter). /api/results?by=all reads the worker-computed,
// deduped rollup_national_previous table instead -- see queries.py's get_results_all. Cached at
// module level since repeated visits to National shouldn't re-fetch.
async function nationalPreviousBreakdown() {
  if (!nationalPreviousData) {
    const data = await fetchJSON('/api/results?by=all');
    nationalPreviousData = data.previous;
  }
  return nationalPreviousData;
}

function renderLeanTab() {
  const tab = document.getElementById('lean-tab');
  tab.innerHTML = '';

  const allRows = allLeanClubRows();
  if (!allRows.length) {
    const empty = document.createElement('p');
    empty.className = 'note';
    empty.textContent = t('analyticsTooFewVotes');
    tab.appendChild(empty);
    return;
  }

  const axisToggle = document.createElement('div');
  axisToggle.className = 'lean-axis-toggle';
  const axisToggleLabel = document.createElement('span');
  axisToggleLabel.textContent = t('analyticsPositionBy');
  axisToggle.appendChild(axisToggleLabel);

  const strip = document.createElement('div');
  strip.className = 'lean-strip';
  const detail = document.createElement('div');
  detail.className = 'card';

  // One shared tooltip rather than one per dot -- only ever one is visible.
  const tip = document.createElement('span');
  tip.className = 'lean-tip';
  tip.hidden = true;
  strip.appendChild(tip);

  const picker = document.createElement('select');
  picker.className = 'lean-picker';

  const axisLabels = document.createElement('div');
  axisLabels.className = 'lean-axis-labels';
  const leftLabel = document.createElement('span');
  const rightLabel = document.createElement('span');
  axisLabels.appendChild(leftLabel);
  axisLabels.appendChild(rightLabel);

  const dotByClubId = new Map();

  async function selectClub(row, dot) {
    strip.querySelectorAll('.lean-dot').forEach(d => d.setAttribute('aria-pressed', 'false'));
    if (dot) dot.setAttribute('aria-pressed', 'true');
    picker.value = row ? String(row.club.id) : '';
    if (row) {
      renderLeanDetail(detail, localizedName(row.club), row.previous);
      return;
    }
    try {
      const national = await nationalPreviousBreakdown();
      renderLeanDetail(detail, t('analyticsNational'), national);
    } catch (err) {
      analyticsShowError('lean-tab');
    }
  }

  // Dots are created ONCE, for every club that clears the vote threshold on any axis, and are then
  // only repositioned when the axis changes. That is what lets them slide: rebuilding the strip per
  // axis would destroy and recreate the elements, and a brand-new element cannot transition from a
  // position its predecessor held.
  allRows.forEach(row => {
    const dot = document.createElement('button');
    dot.type = 'button';
    dot.className = 'lean-dot';
    dot.setAttribute('aria-pressed', 'false');
    dot.setAttribute('aria-label', localizedName(row.club));

    const showTip = () => {
      tip.textContent = localizedName(row.club);
      tip.style.left = dot.style.left;
      tip.hidden = false;
    };
    const hideTip = () => { tip.hidden = true; };
    dot.addEventListener('mouseenter', showTip);
    dot.addEventListener('mouseleave', hideTip);
    dot.addEventListener('focus', showTip);
    dot.addEventListener('blur', hideTip);
    dot.addEventListener('click', () => { showTip(); selectClub(row, dot); });

    dotByClubId.set(row.club.id, dot);
    strip.appendChild(dot);
  });

  picker.addEventListener('change', () => {
    const row = allRows.find(r => String(r.club.id) === picker.value);
    selectClub(row || null, row ? dotByClubId.get(row.club.id) : null);
  });

  function applyAxis() {
    const axis = leanAxisConfig(leanAxis);
    const layout = layoutLeanDots(allRows, leanAxis);

    axisToggle.querySelectorAll('button').forEach(btn => {
      btn.setAttribute('aria-pressed', String(btn.dataset.axis === leanAxis));
    });
    leftLabel.textContent = `\u2190 ${t(axis.negKey)}`;
    rightLabel.textContent = `${t(axis.posKey)} \u2192`;

    allRows.forEach(row => {
      const dot = dotByClubId.get(row.club.id);
      const place = layout.get(row.club.id);
      if (!place) {
        // No value on this axis -- e.g. a fanbase voting only for parties that are NULL on
        // religion-and-state. Hide rather than park it at a misleading 0.
        dot.hidden = true;
        return;
      }
      dot.hidden = false;
      dot.style.left = `${place.x}%`;
      dot.style.top = `${0.55 + place.lane * 0.95}rem`;
    });

    // Keep the picker to clubs that exist on the current axis.
    const selected = picker.value;
    picker.innerHTML = '';
    const nationalOpt = document.createElement('option');
    nationalOpt.value = '';
    nationalOpt.textContent = t('analyticsNational');
    picker.appendChild(nationalOpt);
    allRows
      .filter(row => layout.has(row.club.id))
      .sort((a, b) => localizedName(a.club).localeCompare(localizedName(b.club)))
      .forEach(row => {
        const opt = document.createElement('option');
        opt.value = String(row.club.id);
        opt.textContent = localizedName(row.club);
        picker.appendChild(opt);
      });
    picker.value = layout.has(Number(selected)) ? selected : picker.value;
  }

  LEAN_AXES.forEach(a => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.dataset.axis = a.key;
    btn.textContent = t(a.shortKey);
    btn.setAttribute('aria-pressed', String(a.key === leanAxis));
    btn.addEventListener('click', () => { leanAxis = a.key; applyAxis(); });
    axisToggle.appendChild(btn);
  });

  const pickerRow = document.createElement('label');
  pickerRow.className = 'lean-picker-row';
  const pickerLabel = document.createElement('span');
  pickerLabel.textContent = t('analyticsPickClub');
  pickerRow.appendChild(pickerLabel);
  pickerRow.appendChild(picker);

  tab.appendChild(axisToggle);
  tab.appendChild(strip);
  tab.appendChild(axisLabels);
  tab.appendChild(pickerRow);
  tab.appendChild(detail);

  applyAxis();
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
    analyticsShowError('lean-tab');
    analyticsShowError('switching-tab');
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
