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
    row.innerHTML = `
      <div class="bar-label">${label}</div>
      <div class="bar-track"><div class="bar-fill" style="width:${pct}%"></div></div>
      <div class="bar-count">${r.count}</div>
    `;
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

async function loadResultsByClubOrLeague() {
  const clubId = document.getElementById('club-picker').value;
  const leagueId = document.getElementById('league-picker').value;

  const query = clubId ? `by=club&id=${clubId}` : `by=league&id=${leagueId}`;
  const res = await fetch(`/api/results?${query}`);
  const data = await res.json();

  renderBars('previous-results', data.previous.map(r => ({ count: r.count, key: r.party_id })), r => previousPartyName(r.key));
  renderBars('upcoming-results', data.upcoming.map(r => ({ count: r.count, key: r.party_id })), r => upcomingPartyName(r.key));
}

async function loadResultsByParty() {
  const partyType = document.getElementById('party-type-picker').value;
  const partyId = document.getElementById('party-picker').value;
  if (!partyId) return;

  const res = await fetch(`/api/results?by=party&type=${partyType}&id=${partyId}`);
  const data = await res.json();

  const targetId = partyType === 'previous' ? 'previous-results' : 'upcoming-results';
  const otherId = partyType === 'previous' ? 'upcoming-results' : 'previous-results';
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
  const res = await fetch('/api/options');
  optionsData = await res.json();

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
