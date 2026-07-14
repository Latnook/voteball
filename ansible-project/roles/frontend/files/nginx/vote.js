let optionsData = null;

function renderLeagueOptions() {
  const leagueSelect = document.getElementById('league-select');
  const previousValue = leagueSelect.value;
  leagueSelect.innerHTML = '';
  optionsData.leagues.forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = localizedName(l);
    leagueSelect.appendChild(opt);
  });
  if (previousValue) leagueSelect.value = previousValue;
}

function renderClubs() {
  const leagueSelect = document.getElementById('league-select');
  const clubSelect = document.getElementById('club-select');
  const previousValue = clubSelect.value;
  clubSelect.querySelectorAll('option:not(:first-child)').forEach(o => o.remove());
  const leagueId = parseInt(leagueSelect.value, 10);
  optionsData.clubs.filter(c => c.league_id === leagueId).forEach(c => {
    const opt = document.createElement('option');
    opt.value = c.id;
    opt.textContent = localizedName(c);
    clubSelect.appendChild(opt);
  });
  if (previousValue) clubSelect.value = previousValue;
}

function renderPreviousPartyOptions() {
  const prevDiv = document.getElementById('previous-party-options');
  const checkedInput = document.querySelector('input[name="previous"]:checked');
  const checkedId = checkedInput ? checkedInput.value : null;
  prevDiv.innerHTML = '';
  optionsData.previous_parties.forEach(p => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'radio';
    input.name = 'previous';
    input.value = p.id;
    if (String(p.id) === checkedId) input.checked = true;
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + localizedName(p)));
    prevDiv.appendChild(label);
  });
}

function renderUpcomingPartyOptions() {
  const upcomingDiv = document.getElementById('upcoming-party-options');
  const checkedIds = new Set(Array.from(document.querySelectorAll('.upcoming-checkbox:checked')).map(cb => cb.value));
  upcomingDiv.innerHTML = '';
  optionsData.upcoming_parties.forEach(p => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.className = 'upcoming-checkbox';
    input.value = p.id;
    if (checkedIds.has(String(p.id))) input.checked = true;
    input.addEventListener('change', enforceUpcomingPartyLimit);
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + localizedName(p)));
    upcomingDiv.appendChild(label);
  });
  enforceUpcomingPartyLimit();
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

  renderLeagueOptions();
  document.getElementById('league-select').addEventListener('change', renderClubs);
  renderClubs();
  renderPreviousPartyOptions();
  renderUpcomingPartyOptions();
}

function enforceUpcomingPartyLimit() {
  const checkboxes = document.querySelectorAll('.upcoming-checkbox');
  const checkedCount = document.querySelectorAll('.upcoming-checkbox:checked').length;
  checkboxes.forEach(cb => {
    cb.disabled = !cb.checked && checkedCount >= 3;
  });
}

function selectedUpcomingPartyIds() {
  return Array.from(document.querySelectorAll('.upcoming-checkbox:checked')).map(cb => parseInt(cb.value, 10));
}

document.getElementById('undecided-checkbox').addEventListener('change', (e) => {
  document.querySelectorAll('.upcoming-checkbox').forEach(cb => {
    cb.disabled = e.target.checked;
    if (e.target.checked) cb.checked = false;
  });
});

document.getElementById('vote-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errorEl = document.getElementById('error-message');
  errorEl.textContent = '';

  const leagueId = parseInt(document.getElementById('league-select').value, 10);
  const clubValue = document.getElementById('club-select').value;
  const previousChoice = document.querySelector('input[name="previous"]:checked');
  const undecided = document.getElementById('undecided-checkbox').checked;
  const upcomingIds = selectedUpcomingPartyIds();

  if (!leagueId || !previousChoice) {
    errorEl.textContent = t('voteErrorRequiredFields');
    return;
  }
  if (!undecided && upcomingIds.length === 0) {
    errorEl.textContent = t('voteErrorPickParty');
    return;
  }

  const body = {
    league_id: leagueId,
    club_id: clubValue ? parseInt(clubValue, 10) : null,
    previous_vote_status: previousChoice.value === 'did_not_vote' ? 'did_not_vote' : 'voted',
    previous_party_id: previousChoice.value === 'did_not_vote' ? null : parseInt(previousChoice.value, 10),
    upcoming_vote_status: undecided ? 'undecided' : 'considering',
    upcoming_party_ids: undecided ? [] : upcomingIds,
  };

  const res = await fetch('/api/vote', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

  if (res.status === 409) {
    window.location.href = 'results.html';
    return;
  }
  if (!res.ok) {
    errorEl.textContent = t('voteErrorSubmit');
    return;
  }
  window.location.href = 'results.html';
});

document.addEventListener('voteball:langchange', () => {
  if (!optionsData) return;
  renderLeagueOptions();
  renderClubs();
  renderPreviousPartyOptions();
  renderUpcomingPartyOptions();
});

loadOptions();
