let optionsData = null;
let picksByLeague = new Map(); // leagueId -> { justLeague: bool, clubIds: Set<clubId> }
let selectedLeagueId = null; // active tab, for rendering only
let selectedPreviousChoice = null; // 'did_not_vote' or a previous_party id (number)
let selectedUpcomingIds = new Set();
let undecided = false;
let mode = 'form'; // 'form' | 'review'

function clubsForLeague(leagueId) {
  return optionsData.clubs.filter(c => c.league_id === leagueId || c.domestic_league_id === leagueId);
}

function readLeagueEntry(leagueId) {
  return picksByLeague.get(leagueId) || { justLeague: false, clubIds: new Set() };
}

function getOrCreateLeagueEntry(leagueId) {
  if (!picksByLeague.has(leagueId)) {
    picksByLeague.set(leagueId, { justLeague: false, clubIds: new Set() });
  }
  return picksByLeague.get(leagueId);
}

function hasAnyTeamPick() {
  for (const entry of picksByLeague.values()) {
    if (entry.justLeague || entry.clubIds.size > 0) return true;
  }
  return false;
}

// Single source of truth for "what did the voter actually pick" -- a dual-league club mirrored
// into two leagues' clubIds sets (see toggleClub) must only produce one pick here, attributed to
// its domestic league (the club's "home" league) regardless of which tab it was toggled from.
// Iterates optionsData.leagues (display order) so chip/review ordering matches the league tabs.
function dedupedTeamPicks() {
  const picks = [];
  const emittedClubIds = new Set();
  optionsData.leagues.forEach(l => {
    const entry = picksByLeague.get(l.id);
    if (!entry) return;
    if (entry.justLeague) {
      picks.push({ league_id: l.id, club_id: null });
      return;
    }
    entry.clubIds.forEach(clubId => {
      if (emittedClubIds.has(clubId)) return;
      emittedClubIds.add(clubId);
      const club = optionsData.clubs.find(c => c.id === clubId);
      const canonicalLeagueId = (club && club.domestic_league_id) ? club.domestic_league_id : l.id;
      picks.push({ league_id: canonicalLeagueId, club_id: clubId });
    });
  });
  return picks;
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
    tab.dataset.leagueId = l.id;
    tab.appendChild(logoEl(l, localizedName(l)));
    tab.appendChild(document.createTextNode(localizedName(l)));
    tab.addEventListener('click', () => selectLeague(l.id));
    tabs.appendChild(tab);
  });
}

function selectLeague(leagueId) {
  selectedLeagueId = leagueId;
  renderLeagueTabs();
  renderTeamGrid();
}

function toggleJustLeague(leagueId) {
  const entry = getOrCreateLeagueEntry(leagueId);
  if (entry.justLeague) {
    entry.justLeague = false;
  } else {
    entry.justLeague = true;
    entry.clubIds.clear();
  }
  renderTeamGrid();
  renderPicksSummary();
}

// A dual-league club (has both league_id and domestic_league_id) is votable under two league
// tabs at once. Returns the OTHER league's id if club is dual-league and leagueId is one of its
// two real leagues, else null (no linking for a single-league club).
function linkedLeagueId(club, leagueId) {
  if (!club || !club.domestic_league_id) return null;
  return leagueId === club.league_id ? club.domestic_league_id : club.league_id;
}

function toggleClub(leagueId, clubId) {
  const club = optionsData.clubs.find(c => c.id === clubId);
  const linkedId = linkedLeagueId(club, leagueId);

  const entry = getOrCreateLeagueEntry(leagueId);
  entry.justLeague = false;

  if (entry.clubIds.has(clubId)) {
    // Deselecting -- mirror the removal to the linked league too, so it's picked under both or
    // neither, never split.
    entry.clubIds.delete(clubId);
    if (linkedId !== null) getOrCreateLeagueEntry(linkedId).clubIds.delete(clubId);
  } else {
    // Selecting -- only allow if this league AND (for a dual-league club) its linked league both
    // have room; a dual-league club counts against both leagues' independent 3-pick caps.
    const linkedEntry = linkedId !== null ? getOrCreateLeagueEntry(linkedId) : null;
    const hasRoom = entry.clubIds.size < 3 && (!linkedEntry || linkedEntry.clubIds.size < 3);
    if (hasRoom) {
      entry.clubIds.add(clubId);
      if (linkedEntry) linkedEntry.clubIds.add(clubId);
    }
  }
  renderTeamGrid();
  renderPicksSummary();
}

function renderTeamGrid() {
  const grid = document.getElementById('team-grid');
  grid.innerHTML = '';
  if (selectedLeagueId == null) return;
  const entry = readLeagueEntry(selectedLeagueId);

  const justLeague = document.createElement('button');
  justLeague.type = 'button';
  justLeague.className = 'pick-card utility-card';
  justLeague.setAttribute('aria-pressed', String(entry.justLeague));
  const justLeagueName = document.createElement('span');
  justLeagueName.className = 'card-name';
  justLeagueName.textContent = t('voteClubPlaceholderOption');
  justLeague.appendChild(justLeagueName);
  justLeague.addEventListener('click', () => toggleJustLeague(selectedLeagueId));
  grid.appendChild(justLeague);

  const atCap = entry.clubIds.size >= 3;
  clubsForLeague(selectedLeagueId).forEach(c => {
    const isChecked = entry.clubIds.has(c.id);
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'pick-card';
    card.setAttribute('aria-pressed', String(isChecked));
    card.dataset.clubId = c.id;
    if (!isChecked && atCap) {
      card.disabled = true;
      card.setAttribute('aria-disabled', 'true');
    }
    card.appendChild(logoEl(c, localizedName(c)));
    const name = document.createElement('span');
    name.className = 'card-name';
    name.textContent = localizedName(c);
    card.appendChild(name);
    card.addEventListener('click', () => toggleClub(selectedLeagueId, c.id));
    grid.appendChild(card);
  });
}

function renderPicksSummary() {
  const container = document.getElementById('picks-summary');
  container.innerHTML = '';

  const chips = dedupedTeamPicks().map(pick => {
    if (pick.club_id === null) {
      const league = optionsData.leagues.find(l => l.id === pick.league_id);
      return league ? { entity: league, name: localizedName(league) } : null;
    }
    const club = optionsData.clubs.find(c => c.id === pick.club_id);
    return club ? { entity: club, name: localizedName(club) } : null;
  }).filter(Boolean);

  if (chips.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'note';
    empty.textContent = t('votePicksSummaryEmpty');
    container.appendChild(empty);
    return;
  }

  const label = document.createElement('p');
  label.className = 'note';
  label.textContent = t('votePicksSummaryLabel');
  container.appendChild(label);

  const chipRow = document.createElement('div');
  chipRow.className = 'picks-summary-chips';
  chips.forEach(({ entity, name }) => {
    const chip = document.createElement('span');
    chip.className = 'picks-summary-chip';
    chip.appendChild(logoEl(entity, name));
    const nameSpan = document.createElement('span');
    nameSpan.textContent = name;
    chip.appendChild(nameSpan);
    chipRow.appendChild(chip);
  });
  container.appendChild(chipRow);
}

function renderPreviousGrid() {
  const grid = document.getElementById('previous-grid');
  grid.innerHTML = '';

  // 'Other' is a catch-all with no real logo (see seed.sql), and reads better as a plain text
  // option grouped with the didn't-vote utility card than as a big logo square among real parties.
  const otherParty = optionsData.previous_parties.find(p => p.name_en === 'Other');

  optionsData.previous_parties.filter(p => p !== otherParty).forEach(p => {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'pick-card';
    card.setAttribute('aria-pressed', String(selectedPreviousChoice === p.id));
    card.appendChild(logoEl(p, localizedName(p), { extraClass: 'logo-wide', recolor: true }));
    const name = document.createElement('span');
    name.className = 'card-name';
    name.textContent = localizedName(p);
    card.appendChild(name);
    card.addEventListener('click', () => { selectedPreviousChoice = p.id; renderPreviousGrid(); });
    grid.appendChild(card);
  });

  if (otherParty) {
    const otherCard = document.createElement('button');
    otherCard.type = 'button';
    otherCard.className = 'pick-card utility-card';
    otherCard.setAttribute('aria-pressed', String(selectedPreviousChoice === otherParty.id));
    const otherName = document.createElement('span');
    otherName.className = 'card-name';
    otherName.textContent = localizedName(otherParty);
    otherCard.appendChild(otherName);
    otherCard.addEventListener('click', () => { selectedPreviousChoice = otherParty.id; renderPreviousGrid(); });
    grid.appendChild(otherCard);
  }

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
    card.appendChild(logoEl(p, localizedName(p), { extraClass: 'logo-wide', recolor: true }));
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

function appendReviewLine(container, label, entity, name) {
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

function appendReviewSubheading(container, text) {
  const heading = document.createElement('div');
  heading.className = 'review-subheading';
  heading.textContent = text;
  container.appendChild(heading);
}

function renderReviewSummary() {
  const container = document.getElementById('review-summary');
  container.innerHTML = '';

  appendReviewSubheading(container, t('voteReviewTeams'));
  dedupedTeamPicks().forEach(pick => {
    const league = optionsData.leagues.find(l => l.id === pick.league_id);
    if (!league) return;
    if (pick.club_id === null) {
      appendReviewLine(container, localizedName(league), league, t('voteClubPlaceholderOption'));
    } else {
      const club = optionsData.clubs.find(c => c.id === pick.club_id);
      if (club) appendReviewLine(container, localizedName(league), club, localizedName(club));
    }
  });

  appendReviewSubheading(container, t('voteReviewPrevious'));
  if (selectedPreviousChoice === 'did_not_vote') {
    appendReviewLine(container, '', null, t('voteDidNotVote'));
  } else {
    const party = optionsData.previous_parties.find(p => p.id === selectedPreviousChoice);
    if (party) appendReviewLine(container, '', party, localizedName(party));
  }

  appendReviewSubheading(container, t('voteReviewUpcoming'));
  if (undecided || selectedUpcomingIds.size === 0) {
    appendReviewLine(container, '', null, t('voteUndecided'));
  } else {
    selectedUpcomingIds.forEach(id => {
      const party = optionsData.upcoming_parties.find(p => p.id === id);
      if (party) appendReviewLine(container, '', party, localizedName(party));
    });
  }
}

function enterReviewMode() {
  mode = 'review';
  document.getElementById('form-view').hidden = true;
  document.getElementById('review-view').hidden = false;
  document.getElementById('review-error-message').textContent = '';
  renderReviewSummary();
}

function exitReviewMode() {
  mode = 'form';
  document.getElementById('form-view').hidden = false;
  document.getElementById('review-view').hidden = true;
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
  renderPicksSummary();
  renderPreviousGrid();
  renderUpcomingGrid();
}

document.getElementById('vote-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const errorEl = document.getElementById('error-message');
  errorEl.textContent = '';

  if (!hasAnyTeamPick() || !selectedPreviousChoice) {
    errorEl.textContent = t('voteErrorRequiredFields');
    return;
  }
  if (!undecided && selectedUpcomingIds.size === 0) {
    errorEl.textContent = t('voteErrorPickParty');
    return;
  }

  enterReviewMode();
});

document.getElementById('edit-btn').addEventListener('click', exitReviewMode);

document.getElementById('confirm-submit-btn').addEventListener('click', async () => {
  const errorEl = document.getElementById('review-error-message');
  errorEl.textContent = '';

  const body = {
    team_picks: dedupedTeamPicks(),
    previous_vote_status: selectedPreviousChoice === 'did_not_vote' ? 'did_not_vote' : 'voted',
    previous_party_id: selectedPreviousChoice === 'did_not_vote' ? null : selectedPreviousChoice,
    upcoming_vote_status: undecided ? 'undecided' : 'considering',
    upcoming_party_ids: undecided ? [] : Array.from(selectedUpcomingIds),
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
  window.location.href = '/results';
});

document.addEventListener('voteball:langchange', () => {
  if (!optionsData) return;
  renderLeagueTabs();
  renderTeamGrid();
  renderPicksSummary();
  renderPreviousGrid();
  renderUpcomingGrid();
  if (mode === 'review') renderReviewSummary();
});

loadOptions();
