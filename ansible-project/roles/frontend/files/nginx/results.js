let optionsData = null;
let lastClubLeagueData = null;
let lastPartyData = null;

async function fetchJSON(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`request failed with status ${res.status}`);
  return res.json();
}

function showError(containerIds) {
  containerIds.forEach(id => {
    const el = document.getElementById(id);
    if (!el) return;
    el.innerHTML = '';
    const p = document.createElement('p');
    p.className = 'error';
    p.textContent = t('resultsErrorLoad');
    el.appendChild(p);
  });
}

function previousPartyInfo(id) {
  if (id === null) return { name: t('resultsDidNotVote'), entity: null };
  const p = optionsData.previous_parties.find(p => p.id === id);
  return p ? { name: localizedName(p), entity: p } : { name: `#${id}`, entity: null };
}

function upcomingPartyInfo(id) {
  if (id === null) return { name: t('resultsUndecided'), entity: null };
  const p = optionsData.upcoming_parties.find(p => p.id === id);
  return p ? { name: localizedName(p), entity: p } : { name: `#${id}`, entity: null };
}

function clubOrLeagueInfo(row) {
  if (row.club_id) {
    const c = optionsData.clubs.find(c => c.id === row.club_id);
    return c ? { name: localizedName(c), entity: c } : { name: `club #${row.club_id}`, entity: null };
  }
  const l = optionsData.leagues.find(l => l.id === row.league_id);
  return l ? { name: `${localizedName(l)}${t('resultsLeagueWideSuffix')}`, entity: l } : { name: `league #${row.league_id}`, entity: null };
}

// rows: [{count, ...key fields}]. infoFn(row) -> {name, entity}. opts.highlightKey(row) -> bool.
function renderStandings(containerId, rows, infoFn, opts) {
  opts = opts || {};
  const container = document.getElementById(containerId);
  container.innerHTML = '';

  if (!rows.length) {
    const empty = document.createElement('p');
    empty.className = 'note';
    empty.textContent = opts.emptyText || t('resultsNoData');
    container.appendChild(empty);
    return;
  }

  const total = rows.reduce((sum, r) => sum + r.count, 0) || 1;
  const sorted = rows.slice().sort((a, b) => b.count - a.count);

  sorted.forEach((r, idx) => {
    const { name, entity } = infoFn(r);
    const pct = Math.round((r.count / total) * 100);
    const isYou = typeof opts.highlightKey === 'function' && opts.highlightKey(r);

    const row = document.createElement('div');
    row.className = isYou ? 'standings-row is-you' : 'standings-row';

    const rank = document.createElement('div');
    rank.className = 'standings-rank';
    rank.textContent = String(idx + 1);

    const nameDiv = document.createElement('div');
    nameDiv.className = 'standings-name';
    nameDiv.appendChild(logoEl(entity, name));
    const nameSpan = document.createElement('span');
    nameSpan.textContent = name;
    nameDiv.appendChild(nameSpan);
    if (isYou) {
      const badge = document.createElement('span');
      badge.className = 'standings-you-badge';
      badge.textContent = opts.badgeText || t('resultsYouBadge');
      nameDiv.appendChild(badge);
    }

    const track = document.createElement('div');
    track.className = 'standings-track';
    const fill = document.createElement('div');
    fill.className = 'standings-fill';
    fill.style.width = `${pct}%`;
    track.appendChild(fill);

    const stat = document.createElement('div');
    stat.className = 'standings-stat';
    stat.textContent = `${r.count} · ${pct}%`;

    row.appendChild(rank);
    row.appendChild(nameDiv);
    row.appendChild(track);
    row.appendChild(stat);
    container.appendChild(row);
  });
}

async function loadNationalStandings() {
  try {
    const data = await fetchJSON('/api/results?by=all');
    renderStandings('national-previous', data.previous.map(r => ({ count: r.count, party_id: r.party_id })), r => previousPartyInfo(r.party_id));
    renderStandings('national-upcoming', data.upcoming.map(r => ({ count: r.count, party_id: r.party_id })), r => upcomingPartyInfo(r.party_id));
  } catch (err) {
    showError(['national-previous', 'national-upcoming']);
  }
}

function loadLastVote() {
  try {
    const raw = sessionStorage.getItem('voteballLastVote');
    return raw ? JSON.parse(raw) : null;
  } catch (err) {
    return null;
  }
}

function appendScoreboardLine(container, label, entity, name) {
  const line = document.createElement('div');
  line.className = 'scoreboard-line';
  const labelSpan = document.createElement('span');
  labelSpan.className = 'scoreboard-label';
  labelSpan.textContent = label;
  line.appendChild(labelSpan);
  line.appendChild(logoEl(entity, name));
  const nameSpan = document.createElement('span');
  nameSpan.textContent = name;
  line.appendChild(nameSpan);
  container.appendChild(line);
}

// pick: {league_id, club_id|null} from vote.team_picks. Resolves to the club if set, else the
// league itself (a "just this league" pick).
function pickInfo(pick) {
  const club = pick.club_id ? optionsData.clubs.find(c => c.id === pick.club_id) : null;
  const league = optionsData.leagues.find(l => l.id === pick.league_id);
  const entity = club || league || null;
  const name = club ? localizedName(club) : (league ? localizedName(league) : '');
  return { entity, name, club, league };
}

function renderScoreboard(vote) {
  const el = document.getElementById('compare-scoreboard');
  el.innerHTML = '';

  const title = document.createElement('div');
  title.className = 'scoreboard-title';
  title.textContent = t('resultsYourLineup');
  el.appendChild(title);

  vote.team_picks.forEach((pick, idx) => {
    const info = pickInfo(pick);
    appendScoreboardLine(el, idx === 0 ? t('resultsScoreLabelTeam') : '', info.entity, info.name);
  });

  const prevInfo = previousPartyInfo(vote.previous_party_id);
  appendScoreboardLine(el, t('resultsScoreLabelPrevious'), prevInfo.entity, prevInfo.name);

  if (vote.upcoming_vote_status === 'considering' && vote.upcoming_party_ids.length) {
    vote.upcoming_party_ids.forEach((id, idx) => {
      const info = upcomingPartyInfo(id);
      appendScoreboardLine(el, idx === 0 ? t('resultsScoreLabelUpcoming') : '', info.entity, info.name);
    });
  } else {
    appendScoreboardLine(el, t('resultsScoreLabelUpcoming'), null, t('resultsUndecided'));
  }
}

let compareScopeIndex = 0;

function renderScopePicker(vote) {
  const container = document.getElementById('scope-picker');
  container.innerHTML = '';
  if (vote.team_picks.length <= 1) return; // nothing to choose between with a single pick

  vote.team_picks.forEach((pick, idx) => {
    const info = pickInfo(pick);
    const tab = document.createElement('button');
    tab.type = 'button';
    tab.className = 'tab';
    tab.setAttribute('role', 'tab');
    tab.setAttribute('aria-selected', String(idx === compareScopeIndex));
    tab.appendChild(logoEl(info.entity, info.name));
    tab.appendChild(document.createTextNode(info.name));
    tab.addEventListener('click', () => {
      compareScopeIndex = idx;
      renderScopePicker(vote);
      renderFanLeanAndMigration(vote);
    });
    container.appendChild(tab);
  });
}

async function renderFanLeanAndMigration(vote) {
  const pick = vote.team_picks[compareScopeIndex];
  if (!pick) return;
  const { club, league, name: scopeName } = pickInfo(pick);

  document.getElementById('fan-lean-heading').textContent = t('resultsFanLeanHeading').replace('{who}', scopeName);
  document.getElementById('fan-lean-note').textContent = club
    ? t('resultsFanLeanNoteClub').replace('{club}', scopeName)
    : t('resultsFanLeanNoteLeague').replace('{league}', scopeName);

  try {
    const query = club ? `by=club&id=${club.id}` : `by=league&id=${pick.league_id}`;
    const data = await fetchJSON(`/api/results?${query}`);
    const highlighted = new Set(vote.upcoming_vote_status === 'considering' ? vote.upcoming_party_ids : [null]);
    renderStandings(
      'fan-lean-standings',
      data.upcoming.map(r => ({ count: r.count, party_id: r.party_id })),
      r => upcomingPartyInfo(r.party_id),
      { highlightKey: r => highlighted.has(r.party_id), badgeText: t('resultsYouBadge') }
    );
  } catch (err) {
    showError(['fan-lean-standings']);
  }

  if (vote.previous_party_id == null) {
    document.getElementById('migration-note').textContent = t('resultsMigrationNoteDidNotVote');
    document.getElementById('migration-standings').innerHTML = '';
    return;
  }

  const previousInfo = previousPartyInfo(vote.previous_party_id);
  try {
    let scopeLabel = scopeName;
    let segmentQuery = club
      ? `club_id=${club.id}`
      : `league_id=${pick.league_id}`;
    let data = await fetchJSON(`/api/results/segment?previous_party_id=${vote.previous_party_id}&${segmentQuery}`);
    if (data.total < 5) {
      // Sample too thin at this scope to be meaningful -- fall back to the national migration.
      data = await fetchJSON(`/api/results/segment?previous_party_id=${vote.previous_party_id}`);
      scopeLabel = t('resultsScopeNational');
    }
    document.getElementById('migration-note').textContent = t('resultsMigrationNote')
      .replace('{party}', previousInfo.name).replace('{scope}', scopeLabel);
    renderStandings(
      'migration-standings',
      data.upcoming.map(r => ({ count: r.count, party_id: r.party_id })),
      r => upcomingPartyInfo(r.party_id)
    );
  } catch (err) {
    showError(['migration-standings']);
  }
}

async function renderCompareSection(vote) {
  if (!vote.team_picks || vote.team_picks.length === 0) return;
  document.getElementById('compare-section').hidden = false;
  document.getElementById('compare-divider').hidden = false;
  compareScopeIndex = 0;

  renderScoreboard(vote);
  renderScopePicker(vote);
  await renderFanLeanAndMigration(vote);
}

function renderClubLeagueResults() {
  if (!lastClubLeagueData) return;
  renderStandings('previous-results', lastClubLeagueData.previous.map(r => ({ count: r.count, party_id: r.party_id })), r => previousPartyInfo(r.party_id));
  renderStandings('upcoming-results', lastClubLeagueData.upcoming.map(r => ({ count: r.count, party_id: r.party_id })), r => upcomingPartyInfo(r.party_id));
}

async function loadResultsByClubOrLeague() {
  const clubId = document.getElementById('club-picker').value;
  const leagueId = document.getElementById('league-picker').value;
  const query = clubId ? `by=club&id=${clubId}` : `by=league&id=${leagueId}`;
  try {
    lastClubLeagueData = await fetchJSON(`/api/results?${query}`);
  } catch (err) {
    showError(['previous-results', 'upcoming-results']);
    return;
  }
  renderClubLeagueResults();
}

function renderPartyResults() {
  if (!lastPartyData) return;
  const { partyType, targetId, otherId, breakdown, crosstab } = lastPartyData;
  const otherKey = partyType === 'previous' ? 'upcoming_party_id' : 'previous_party_id';
  const otherInfoFn = partyType === 'previous' ? (r => upcomingPartyInfo(r.key)) : (r => previousPartyInfo(r.key));

  renderStandings(targetId, breakdown.map(r => ({ count: r.count, club_id: r.club_id, league_id: r.league_id })), clubOrLeagueInfo);
  renderStandings(otherId, crosstab.map(r => ({ count: r.count, key: r[otherKey] })), otherInfoFn);
}

async function loadResultsByParty() {
  const partyType = document.getElementById('party-type-picker').value;
  const partyId = document.getElementById('party-picker').value;
  if (!partyId) return;

  const targetId = partyType === 'previous' ? 'previous-results' : 'upcoming-results';
  const otherId = partyType === 'previous' ? 'upcoming-results' : 'previous-results';

  let data;
  try {
    data = await fetchJSON(`/api/results?by=party&type=${partyType}&id=${partyId}`);
  } catch (err) {
    showError([targetId, otherId]);
    return;
  }

  lastPartyData = { partyType, targetId, otherId, breakdown: data.breakdown, crosstab: data.crosstab };
  renderPartyResults();
}

function renderLeaguePickerOptions() {
  const leaguePicker = document.getElementById('league-picker');
  const previousValue = leaguePicker.value;
  leaguePicker.innerHTML = '';
  optionsData.leagues.forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = localizedName(l);
    leaguePicker.appendChild(opt);
  });
  if (previousValue) leaguePicker.value = previousValue;
}

function renderClubPickerOptions() {
  const leaguePicker = document.getElementById('league-picker');
  const clubPicker = document.getElementById('club-picker');
  const previousValue = clubPicker.value;
  clubPicker.querySelectorAll('option:not(:first-child)').forEach(o => o.remove());
  const leagueId = parseInt(leaguePicker.value, 10);
  optionsData.clubs.filter(c => c.league_id === leagueId || c.domestic_league_id === leagueId).forEach(c => {
    const opt = document.createElement('option');
    opt.value = c.id;
    opt.textContent = localizedName(c);
    clubPicker.appendChild(opt);
  });
  if (previousValue) clubPicker.value = previousValue;
}

function renderPartyPicker() {
  const partyType = document.getElementById('party-type-picker').value;
  const picker = document.getElementById('party-picker');
  const previousValue = picker.value;
  picker.innerHTML = '';
  const list = partyType === 'previous' ? optionsData.previous_parties : optionsData.upcoming_parties;
  list.forEach(p => {
    const opt = document.createElement('option');
    opt.value = p.id;
    opt.textContent = localizedName(p);
    picker.appendChild(opt);
  });
  if (previousValue) picker.value = previousValue;
  loadResultsByParty();
}

function currentExplorerMode() {
  const active = document.querySelector('#mode-toggle button[aria-pressed="true"]');
  return active ? active.dataset.mode : 'club-league';
}

document.getElementById('mode-toggle').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-mode]');
  if (!btn) return;
  document.querySelectorAll('#mode-toggle button').forEach(b => b.setAttribute('aria-pressed', String(b === btn)));
  const isClubLeague = btn.dataset.mode === 'club-league';
  document.getElementById('club-league-mode').hidden = !isClubLeague;
  document.getElementById('party-mode').hidden = isClubLeague;
  if (isClubLeague) loadResultsByClubOrLeague(); else renderPartyPicker();
});

document.getElementById('league-picker').addEventListener('change', () => { renderClubPickerOptions(); loadResultsByClubOrLeague(); });
document.getElementById('club-picker').addEventListener('change', loadResultsByClubOrLeague);
document.getElementById('party-type-picker').addEventListener('change', renderPartyPicker);
document.getElementById('party-picker').addEventListener('change', loadResultsByParty);

async function init() {
  try {
    optionsData = await fetchJSON('/api/options');
  } catch (err) {
    showError(['national-previous', 'national-upcoming', 'previous-results', 'upcoming-results']);
    return;
  }

  loadNationalStandings();

  const lastVote = loadLastVote();
  if (lastVote) renderCompareSection(lastVote);

  renderLeaguePickerOptions();
  renderClubPickerOptions();
  loadResultsByClubOrLeague();
}

document.addEventListener('voteball:langchange', () => {
  if (!optionsData) return;
  loadNationalStandings();
  const lastVote = loadLastVote();
  if (lastVote) renderCompareSection(lastVote);
  renderLeaguePickerOptions();
  renderClubPickerOptions();
  if (currentExplorerMode() === 'party') renderPartyPicker(); else renderClubLeagueResults();
});

init();
