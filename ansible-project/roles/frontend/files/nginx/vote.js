async function loadOptions() {
  const res = await fetch('/api/options');
  const data = await res.json();

  const leagueSelect = document.getElementById('league-select');
  data.leagues.forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = l.name;
    leagueSelect.appendChild(opt);
  });

  const clubSelect = document.getElementById('club-select');
  function renderClubs() {
    clubSelect.querySelectorAll('option:not(:first-child)').forEach(o => o.remove());
    const leagueId = parseInt(leagueSelect.value, 10);
    data.clubs.filter(c => c.league_id === leagueId).forEach(c => {
      const opt = document.createElement('option');
      opt.value = c.id;
      opt.textContent = c.name;
      clubSelect.appendChild(opt);
    });
  }
  leagueSelect.addEventListener('change', renderClubs);
  renderClubs();

  const prevDiv = document.getElementById('previous-party-options');
  data.previous_parties.forEach(p => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'radio';
    input.name = 'previous';
    input.value = p.id;
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + p.name));
    prevDiv.appendChild(label);
  });

  const upcomingDiv = document.getElementById('upcoming-party-options');
  data.upcoming_parties.forEach(p => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.className = 'upcoming-checkbox';
    input.value = p.id;
    label.appendChild(input);
    label.appendChild(document.createTextNode(' ' + p.name));
    upcomingDiv.appendChild(label);
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
    errorEl.textContent = 'Please fill in all required fields.';
    return;
  }
  if (!undecided && upcomingIds.length === 0) {
    errorEl.textContent = 'Pick at least one party you\'re considering, or mark yourself undecided.';
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
    errorEl.textContent = 'Something went wrong submitting your vote.';
    return;
  }
  window.location.href = 'results.html';
});

loadOptions();
