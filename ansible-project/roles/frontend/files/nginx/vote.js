let optionsData = null;
let selectedLeagueId = null;
let selectedClubId = null; // null = "just the league"
let selectedPreviousChoice = null; // 'did_not_vote' or a previous_party id (number)
let selectedUpcomingIds = new Set();
let undecided = false;

function clubsForLeague(leagueId) {
  return optionsData.clubs.filter(c => c.league_id === leagueId || c.domestic_league_id === leagueId);
}

function renderLeagueTabs() {
  const tabs = document.getElementById('league-tabs');
  tabs.innerHTML = '';
  optionsData.leagues.forEach(l => {
    const tab = document.createElement('button');
    tab.type = 'button';
    tab.className = 'tab';
    tab.setAttribute('role', 'tab');
    tab.setAttribute('aria-selected', String(l.id === selectedLeagueId));
    tab.appendChild(logoEl(l, localizedName(l)));
    tab.appendChild(document.createTextNode(localizedName(l)));
    tab.addEventListener('click', () => selectLeague(l.id));
    tabs.appendChild(tab);
  });
}

function selectLeague(leagueId) {
  selectedLeagueId = leagueId;
  const stillValid = clubsForLeague(leagueId).some(c => c.id === selectedClubId);
  if (!stillValid) selectedClubId = null;
  renderLeagueTabs();
  renderTeamGrid();
}

function renderTeamGrid() {
  const grid = document.getElementById('team-grid');
  grid.innerHTML = '';
  if (selectedLeagueId == null) return;

  const justLeague = document.createElement('button');
  justLeague.type = 'button';
  justLeague.className = 'pick-card utility-card';
  justLeague.setAttribute('aria-pressed', String(selectedClubId === null));
  const justLeagueName = document.createElement('span');
  justLeagueName.className = 'card-name';
  justLeagueName.textContent = t('voteClubPlaceholderOption');
  justLeague.appendChild(justLeagueName);
  justLeague.addEventListener('click', () => { selectedClubId = null; renderTeamGrid(); });
  grid.appendChild(justLeague);

  clubsForLeague(selectedLeagueId).forEach(c => {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'pick-card';
    card.setAttribute('aria-pressed', String(c.id === selectedClubId));
    card.appendChild(logoEl(c, localizedName(c)));
    const name = document.createElement('span');
    name.className = 'card-name';
    name.textContent = localizedName(c);
    card.appendChild(name);
    card.addEventListener('click', () => { selectedClubId = c.id; renderTeamGrid(); });
    grid.appendChild(card);
  });
}

function renderPreviousGrid() {
  const grid = document.getElementById('previous-grid');
  grid.innerHTML = '';

  optionsData.previous_parties.forEach(p => {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'pick-card';
    card.setAttribute('aria-pressed', String(selectedPreviousChoice === p.id));
    card.appendChild(logoEl(p, localizedName(p)));
    const name = document.createElement('span');
    name.className = 'card-name';
    name.textContent = localizedName(p);
    card.appendChild(name);
    card.addEventListener('click', () => { selectedPreviousChoice = p.id; renderPreviousGrid(); });
    grid.appendChild(card);
  });

  const didNotVote = document.createElement('button');
  didNotVote.type = 'button';
  didNotVote.className = 'pick-card utility-card';
  didNotVote.setAttribute('aria-pressed', String(selectedPreviousChoice === 'did_not_vote'));
  const didNotVoteName = document.createElement('span');
  didNotVoteName.className = 'card-name';
  didNotVoteName.textContent = t('voteDidNotVote');
  didNotVote.appendChild(didNotVoteName);
  didNotVote.addEventListener('click', () => { selectedPreviousChoice = 'did_not_vote'; renderPreviousGrid(); });
  grid.appendChild(didNotVote);
}

function toggleUpcoming(partyId) {
  if (undecided) undecided = false;
  if (selectedUpcomingIds.has(partyId)) {
    selectedUpcomingIds.delete(partyId);
  } else if (selectedUpcomingIds.size < 3) {
    selectedUpcomingIds.add(partyId);
  }
  renderUpcomingGrid();
}

function renderUpcomingGrid() {
  const grid = document.getElementById('upcoming-grid');
  grid.innerHTML = '';
  const atCap = selectedUpcomingIds.size >= 3;

  optionsData.upcoming_parties.forEach(p => {
    const isChecked = selectedUpcomingIds.has(p.id);
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'pick-card';
    card.setAttribute('aria-pressed', String(isChecked));
    if (!isChecked && atCap) {
      card.disabled = true;
      card.setAttribute('aria-disabled', 'true');
    }
    card.appendChild(logoEl(p, localizedName(p)));
    const name = document.createElement('span');
    name.className = 'card-name';
    name.textContent = localizedName(p);
    card.appendChild(name);
    card.addEventListener('click', () => toggleUpcoming(p.id));
    grid.appendChild(card);
  });

  const undecidedCard = document.createElement('button');
  undecidedCard.type = 'button';
  undecidedCard.className = 'pick-card utility-card';
  undecidedCard.setAttribute('aria-pressed', String(undecided));
  const undecidedName = document.createElement('span');
  undecidedName.className = 'card-name';
  undecidedName.textContent = t('voteUndecided');
  undecidedCard.appendChild(undecidedName);
  undecidedCard.addEventListener('click', () => {
    undecided = !undecided;
    if (undecided) selectedUpcomingIds.clear();
    renderUpcomingGrid();
  });
  grid.appendChild(undecidedCard);
}

async function loadOptions() {
  try {
    const res = await fetch('/api/options');
    if (!res.ok) throw new Error(`request failed with status ${res.status}`);
    optionsData = await res.json();
  } catch (err) {
    document.getElementById('error-message').textContent = t('voteErrorLoadForm');
    return;
  }

  if (optionsData.leagues.length > 0) selectedLeagueId = optionsData.leagues[0].id;
  renderLeagueTabs();
  renderTeamGrid();
  renderPreviousGrid();
  renderUpcomingGrid();
}

document.getElementById('vote-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errorEl = document.getElementById('error-message');
  errorEl.textContent = '';

  if (!selectedLeagueId || !selectedPreviousChoice) {
    errorEl.textContent = t('voteErrorRequiredFields');
    return;
  }
  if (!undecided && selectedUpcomingIds.size === 0) {
    errorEl.textContent = t('voteErrorPickParty');
    return;
  }

  const upcomingIds = Array.from(selectedUpcomingIds);
  const body = {
    league_id: selectedLeagueId,
    club_id: selectedClubId,
    previous_vote_status: selectedPreviousChoice === 'did_not_vote' ? 'did_not_vote' : 'voted',
    previous_party_id: selectedPreviousChoice === 'did_not_vote' ? null : selectedPreviousChoice,
    upcoming_vote_status: undecided ? 'undecided' : 'considering',
    upcoming_party_ids: undecided ? [] : upcomingIds,
  };

  const res = await fetch('/api/vote', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  if (res.status !== 409 && !res.ok) {
    errorEl.textContent = t('voteErrorSubmit');
    return;
  }

  sessionStorage.setItem('voteballLastVote', JSON.stringify(body));
  window.location.href = 'results.html';
});

document.addEventListener('voteball:langchange', () => {
  if (!optionsData) return;
  renderLeagueTabs();
  renderTeamGrid();
  renderPreviousGrid();
  renderUpcomingGrid();
});

loadOptions();
