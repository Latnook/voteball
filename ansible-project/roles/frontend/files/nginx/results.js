let optionsData = null;

function renderBars(containerId, rows, nameLookup) {
  const container = document.getElementById(containerId);
  container.innerHTML = '';
  const total = rows.reduce((sum, r) => sum + r.count, 0) || 1;
  rows.sort((a, b) => b.count - a.count);
  rows.forEach(r => {
    const label = nameLookup(r);
    const pct = Math.round((r.count / total) * 100);
    const row = document.createElement('div');
    row.className = 'bar-row';

    const labelDiv = document.createElement('div');
    labelDiv.className = 'bar-label';
    labelDiv.textContent = label;

    const trackDiv = document.createElement('div');
    trackDiv.className = 'bar-track';
    const fillDiv = document.createElement('div');
    fillDiv.className = 'bar-fill';
    fillDiv.style.width = `${pct}%`;
    trackDiv.appendChild(fillDiv);

    const countDiv = document.createElement('div');
    countDiv.className = 'bar-count';
    countDiv.textContent = r.count;

    row.appendChild(labelDiv);
    row.appendChild(trackDiv);
    row.appendChild(countDiv);
    container.appendChild(row);
  });
}

function previousPartyName(id) {
  if (id === null) return 'Did not vote';
  const p = optionsData.previous_parties.find(p => p.id === id);
  return p ? p.name : `#${id}`;
}

function upcomingPartyName(id) {
  if (id === null) return 'Undecided';
  const p = optionsData.upcoming_parties.find(p => p.id === id);
  return p ? p.name : `#${id}`;
}

function clubOrLeagueName(row) {
  if (row.club_id) {
    const c = optionsData.clubs.find(c => c.id === row.club_id);
    return c ? c.name : `club #${row.club_id}`;
  }
  const l = optionsData.leagues.find(l => l.id === row.league_id);
  return l ? `${l.name} (league-wide)` : `league #${row.league_id}`;
}

function showResultsError(containerIds) {
  containerIds.forEach(id => {
    const el = document.getElementById(id);
    if (el) el.innerHTML = '<p class="error">Couldn\'t load results — try refreshing.</p>';
  });
}

async function loadResultsByClubOrLeague() {
  const clubId = document.getElementById('club-picker').value;
  const leagueId = document.getElementById('league-picker').value;

  const query = clubId ? `by=club&id=${clubId}` : `by=league&id=${leagueId}`;
  let data;
  try {
    const res = await fetch(`/api/results?${query}`);
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    data = await res.json();
  } catch (err) {
    showResultsError(['previous-results', 'upcoming-results']);
    return;
  }

  renderBars('previous-results', data.previous.map(r => ({ count: r.count, key: r.party_id })), r => previousPartyName(r.key));
  renderBars('upcoming-results', data.upcoming.map(r => ({ count: r.count, key: r.party_id })), r => upcomingPartyName(r.key));
}

async function loadResultsByParty() {
  const partyType = document.getElementById('party-type-picker').value;
  const partyId = document.getElementById('party-picker').value;
  if (!partyId) return;

  const targetId = partyType === 'previous' ? 'previous-results' : 'upcoming-results';
  const otherId = partyType === 'previous' ? 'upcoming-results' : 'previous-results';

  let data;
  try {
    const res = await fetch(`/api/results?by=party&type=${partyType}&id=${partyId}`);
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    data = await res.json();
  } catch (err) {
    showResultsError([targetId]);
    return;
  }

  document.getElementById(otherId).innerHTML = '<p>Switch party type to see this breakdown.</p>';
  renderBars(targetId, data.breakdown.map(r => ({ count: r.count, club_id: r.club_id, league_id: r.league_id })), clubOrLeagueName);
}

function renderPartyPicker() {
  const partyType = document.getElementById('party-type-picker').value;
  const picker = document.getElementById('party-picker');
  picker.innerHTML = '';
  const list = partyType === 'previous' ? optionsData.previous_parties : optionsData.upcoming_parties;
  list.forEach(p => {
    const opt = document.createElement('option');
    opt.value = p.id;
    opt.textContent = p.name;
    picker.appendChild(opt);
  });
  loadResultsByParty();
}

async function init() {
  try {
    const res = await fetch('/api/options');
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    optionsData = await res.json();
  } catch (err) {
    showResultsError(['previous-results', 'upcoming-results']);
    return;
  }

  const leaguePicker = document.getElementById('league-picker');
  optionsData.leagues.forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = l.name;
    leaguePicker.appendChild(opt);
  });

  const clubPicker = document.getElementById('club-picker');
  function renderClubs() {
    clubPicker.querySelectorAll('option:not(:first-child)').forEach(o => o.remove());
    const leagueId = parseInt(leaguePicker.value, 10);
    optionsData.clubs.filter(c => c.league_id === leagueId).forEach(c => {
      const opt = document.createElement('option');
      opt.value = c.id;
      opt.textContent = c.name;
      clubPicker.appendChild(opt);
    });
  }
  leaguePicker.addEventListener('change', () => { renderClubs(); loadResultsByClubOrLeague(); });
  clubPicker.addEventListener('change', loadResultsByClubOrLeague);
  renderClubs();

  document.querySelectorAll('input[name="mode"]').forEach(radio => {
    radio.addEventListener('change', () => {
      const isClubLeague = document.querySelector('input[name="mode"]:checked').value === 'club-league';
      document.getElementById('club-league-mode').style.display = isClubLeague ? 'block' : 'none';
      document.getElementById('party-mode').style.display = isClubLeague ? 'none' : 'block';
      if (isClubLeague) loadResultsByClubOrLeague(); else renderPartyPicker();
    });
  });

  document.getElementById('party-type-picker').addEventListener('change', renderPartyPicker);
  document.getElementById('party-picker').addEventListener('change', loadResultsByParty);

  loadResultsByClubOrLeague();
}

init();
