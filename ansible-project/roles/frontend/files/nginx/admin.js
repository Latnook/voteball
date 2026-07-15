const ADMIN_TOKEN_KEY = 'voteballAdminToken';
let optionsData = null;
let lastVotesData = null;
const loadedTabs = new Set();
const openRenameKeys = new Set();

function adminHeaders() {
  return { 'Authorization': 'Bearer ' + (sessionStorage.getItem(ADMIN_TOKEN_KEY) || '') };
}

async function adminFetch(url, options = {}) {
  const headers = Object.assign({}, options.headers, adminHeaders());
  const res = await fetch(url, Object.assign({}, options, { headers }));
  if (res.status === 401) {
    sessionStorage.removeItem(ADMIN_TOKEN_KEY);
    showGate(t('adminSessionExpired'));
    return null;
  }
  return res;
}

function showGate(message) {
  document.getElementById('admin-content').style.display = 'none';
  document.getElementById('secret-gate').style.display = 'block';
  document.getElementById('secret-error').textContent = message || '';
}

function showContent() {
  document.getElementById('secret-gate').style.display = 'none';
  document.getElementById('admin-content').style.display = 'block';
}

async function getOptionsData() {
  if (optionsData) return optionsData;
  const res = await fetch('/api/options');
  optionsData = await res.json();
  return optionsData;
}

function activateTab(tab) {
  document.querySelectorAll('.tab-button').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.tab === tab);
  });
  document.querySelectorAll('.tab-section').forEach(section => {
    section.classList.toggle('active', section.id === `tab-${tab}`);
  });
  loadTab(tab);
}

function loadTab(tab) {
  if (loadedTabs.has(tab)) return;
  loadedTabs.add(tab);
  if (tab === 'teams') loadTeamsTab();
  else if (tab === 'previous') loadPartyTab('previous');
  else if (tab === 'upcoming') loadPartyTab('upcoming');
  else if (tab === 'votes') loadVotesTab();
}

function partyEndpoint(type) {
  return type === 'previous' ? '/api/admin/previous-parties' : '/api/admin/upcoming-parties';
}

function partyListKey(type) {
  return type === 'previous' ? 'previous_parties' : 'upcoming_parties';
}

async function loadPartyTab(type) {
  const data = await getOptionsData();
  renderPartyList(type, data[partyListKey(type)]);
}

function renderPartyList(type, parties) {
  const container = document.getElementById(`${type}-party-list`);
  container.innerHTML = '';
  parties.forEach(party => container.appendChild(renderPartyRow(type, party, parties)));
}

function renderPartyRow(type, party, allParties) {
  const row = document.createElement('div');
  row.className = 'party-row';
  row.dataset.partyId = party.id;

  const nameSpan = document.createElement('span');
  nameSpan.className = 'party-name';
  nameSpan.textContent = localizedName(party);
  row.appendChild(nameSpan);

  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = t('adminRename');
  renameBtn.addEventListener('click', () => startRename(type, party, row));
  row.appendChild(renameBtn);

  const reassignBtn = document.createElement('button');
  reassignBtn.type = 'button';
  reassignBtn.textContent = t('adminReassign');
  reassignBtn.addEventListener('click', () => toggleReassignForm(type, party, allParties, row));
  row.appendChild(reassignBtn);

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.textContent = t('adminDelete');
  deleteBtn.addEventListener('click', () => deleteParty(type, party));
  row.appendChild(deleteBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  row.appendChild(errorSpan);

  return row;
}

function startRename(type, party, row) {
  openRenameKeys.add(`${type}:${party.id}`);
  const nameSpan = row.querySelector('.party-name');
  const inputEn = document.createElement('input');
  inputEn.type = 'text';
  inputEn.value = party.name_en;
  const inputHe = document.createElement('input');
  inputHe.type = 'text';
  inputHe.value = party.name_he;
  inputHe.dir = 'rtl';
  nameSpan.replaceWith(inputEn);
  inputEn.after(inputHe);

  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.textContent = t('adminSave');
  inputHe.after(saveBtn);
  inputEn.focus();

  saveBtn.addEventListener('click', async () => {
    const errorSpan = row.querySelector('.row-error');
    errorSpan.textContent = '';

    let res;
    try {
      res = await adminFetch(`${partyEndpoint(type)}/${party.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name_en: inputEn.value, name_he: inputHe.value }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    openRenameKeys.delete(`${type}:${party.id}`);
    optionsData = null;
    loadedTabs.delete(type);
    loadPartyTab(type);
  });
}

async function deleteParty(type, party) {
  if (!confirm(t('adminConfirmDeleteParty').replace('{name}', localizedName(party)))) return;

  let res;
  try {
    res = await adminFetch(`${partyEndpoint(type)}/${party.id}`, { method: 'DELETE' });
  } catch (err) {
    alert(t('adminSomethingWrong'));
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    alert(body.error || t('adminSomethingWrong'));
    return;
  }
  optionsData = null;
  loadedTabs.delete(type);
  loadPartyTab(type);
}

async function addParty(e, type) {
  e.preventDefault();
  const inputEn = document.getElementById(`${type}-party-add-input-en`);
  const inputHe = document.getElementById(`${type}-party-add-input-he`);
  const errorEl = document.getElementById(`${type}-party-form-error`);
  errorEl.textContent = '';

  let res;
  try {
    res = await adminFetch(partyEndpoint(type), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name_en: inputEn.value, name_he: inputHe.value }),
    });
  } catch (err) {
    errorEl.textContent = t('adminSomethingWrong');
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    errorEl.textContent = body.error || t('adminSomethingWrong');
    return;
  }
  inputEn.value = '';
  inputHe.value = '';
  optionsData = null;
  loadedTabs.delete(type);
  loadPartyTab(type);
}

document.getElementById('previous-party-add-form').addEventListener('submit', (e) => addParty(e, 'previous'));
document.getElementById('upcoming-party-add-form').addEventListener('submit', (e) => addParty(e, 'upcoming'));

document.querySelectorAll('.tab-button').forEach(btn => {
  btn.addEventListener('click', () => activateTab(btn.dataset.tab));
});

document.getElementById('secret-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const username = document.getElementById('username-input').value;
  const password = document.getElementById('password-input').value;
  const errorEl = document.getElementById('secret-error');
  errorEl.textContent = '';

  let res;
  try {
    res = await fetch('/api/admin/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    });
  } catch (err) {
    errorEl.textContent = t('adminSomethingWrongRetry');
    return;
  }

  if (res.status === 401) {
    errorEl.textContent = t('adminIncorrectCredentials');
    document.getElementById('password-input').value = '';
    return;
  }
  if (!res.ok) {
    errorEl.textContent = t('adminSomethingWrongRetry');
    return;
  }

  const { token } = await res.json();
  sessionStorage.setItem(ADMIN_TOKEN_KEY, token);
  showContent();
  activateTab('previous');
});

async function tryEnterWithStoredToken() {
  const stored = sessionStorage.getItem(ADMIN_TOKEN_KEY);
  if (!stored) return;
  let res;
  try {
    res = await fetch('/api/admin/votes', { headers: { 'Authorization': `Bearer ${stored}` } });
  } catch (err) {
    return;
  }
  if (res.ok) {
    showContent();
    activateTab('previous');
  } else {
    sessionStorage.removeItem(ADMIN_TOKEN_KEY);
  }
}

document.getElementById('logout-button').addEventListener('click', () => {
  sessionStorage.removeItem(ADMIN_TOKEN_KEY);
  showGate();
});

tryEnterWithStoredToken();

function toggleReassignForm(type, sourceParty, allParties, row) {
  const existing = row.querySelector('.reassign-form');
  if (existing) {
    existing.remove();
    return;
  }

  const form = document.createElement('div');
  form.className = 'reassign-form';

  const select = document.createElement('select');
  allParties.filter(p => p.id !== sourceParty.id).forEach(p => {
    const opt = document.createElement('option');
    opt.value = p.id;
    opt.textContent = localizedName(p);
    select.appendChild(opt);
  });
  form.appendChild(select);

  const goBtn = document.createElement('button');
  goBtn.type = 'button';
  goBtn.textContent = t('adminReassignGo');
  form.appendChild(goBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  form.appendChild(errorSpan);

  goBtn.addEventListener('click', async () => {
    if (!select.value) return;
    const targetId = parseInt(select.value, 10);
    errorSpan.textContent = '';

    let countRes;
    try {
      countRes = await adminFetch(`${partyEndpoint(type)}/${sourceParty.id}/reassign-count?target_id=${targetId}`);
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (countRes === null) return;
    if (!countRes.ok) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    const { count } = await countRes.json();
    const targetParty = allParties.find(p => p.id === targetId);
    if (!confirm(t('adminConfirmReassign').replace('{count}', count).replace('{source}', localizedName(sourceParty)).replace('{target}', localizedName(targetParty)))) {
      return;
    }

    let res;
    try {
      res = await adminFetch(`${partyEndpoint(type)}/${sourceParty.id}/reassign`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target_id: targetId }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete(type);
    loadedTabs.delete('votes');
    loadPartyTab(type);
  });

  row.appendChild(form);
}

function leagueName(data, id) {
  const l = data.leagues.find(l => l.id === id);
  return l ? localizedName(l) : `league #${id}`;
}

function clubName(data, id) {
  if (id === null) return '—';
  const c = data.clubs.find(c => c.id === id);
  return c ? localizedName(c) : `club #${id}`;
}

function buildLeagueSelect(leagues, excludeId, includeNone) {
  const select = document.createElement('select');
  if (includeNone) {
    const noneOpt = document.createElement('option');
    noneOpt.value = '';
    noneOpt.textContent = t('adminDomesticLeagueNone');
    select.appendChild(noneOpt);
  }
  leagues.filter(l => l.id !== excludeId).forEach(l => {
    const opt = document.createElement('option');
    opt.value = l.id;
    opt.textContent = localizedName(l);
    select.appendChild(opt);
  });
  return select;
}

async function loadTeamsTab() {
  const data = await getOptionsData();
  renderLeagueGroups(data);
}

function renderLeagueGroups(data) {
  const container = document.getElementById('league-list');
  container.innerHTML = '';
  data.leagues.forEach(league => container.appendChild(renderLeagueGroup(league, data)));
}

function renderLeagueGroup(league, data) {
  const group = document.createElement('div');
  group.className = 'league-group';
  group.dataset.leagueId = league.id;

  const header = document.createElement('div');
  header.className = 'party-row league-header';
  const nameSpan = document.createElement('span');
  nameSpan.className = 'party-name';
  nameSpan.textContent = localizedName(league);
  header.appendChild(nameSpan);

  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = t('adminRename');
  renameBtn.addEventListener('click', () => startRenameLeague(league, header));
  header.appendChild(renameBtn);

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.textContent = t('adminDelete');
  deleteBtn.addEventListener('click', () => deleteLeague(league));
  header.appendChild(deleteBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  header.appendChild(errorSpan);

  group.appendChild(header);

  const clubsContainer = document.createElement('div');
  clubsContainer.className = 'club-list';
  data.clubs.filter(c => c.league_id === league.id).forEach(club => {
    clubsContainer.appendChild(renderClubRow(club, data, null));
  });
  data.clubs.filter(c => c.domestic_league_id === league.id).forEach(club => {
    clubsContainer.appendChild(renderClubRow(club, data, club.league_id));
  });
  group.appendChild(clubsContainer);

  group.appendChild(renderAddClubForm(league));

  return group;
}

function renderClubRow(club, data, annotateLeagueId) {
  const row = document.createElement('div');
  row.className = 'party-row club-row';
  row.dataset.clubId = club.id;

  const nameSpan = document.createElement('span');
  nameSpan.className = 'party-name';
  nameSpan.textContent = localizedName(club);
  row.appendChild(nameSpan);

  if (annotateLeagueId !== null) {
    const note = document.createElement('span');
    note.className = 'row-note';
    note.textContent = t('adminAlsoInLeague').replace('{league}', leagueName(data, annotateLeagueId));
    row.appendChild(note);
    return row; // read-only secondary listing under its domestic league group -- edit from its primary row
  }

  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = t('adminRename');
  renameBtn.addEventListener('click', () => startRenameClub(club, data, row));
  row.appendChild(renameBtn);

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.textContent = t('adminDelete');
  deleteBtn.addEventListener('click', () => deleteClub(club));
  row.appendChild(deleteBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  row.appendChild(errorSpan);

  return row;
}

function renderAddClubForm(league) {
  const form = document.createElement('form');
  form.className = 'add-club-form';
  const inputEn = document.createElement('input');
  inputEn.type = 'text';
  inputEn.placeholder = t('adminPlaceholderNameEn');
  inputEn.required = true;
  const inputHe = document.createElement('input');
  inputHe.type = 'text';
  inputHe.placeholder = t('adminPlaceholderNameHe');
  inputHe.dir = 'rtl';
  inputHe.required = true;
  const domesticSelect = buildLeagueSelect(optionsData.leagues, league.id, true);
  const addBtn = document.createElement('button');
  addBtn.type = 'submit';
  addBtn.textContent = t('adminAddClub');
  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';

  [inputEn, inputHe, domesticSelect, addBtn, errorSpan].forEach(el => form.appendChild(el));

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    errorSpan.textContent = '';
    const domesticLeagueId = domesticSelect.value ? parseInt(domesticSelect.value, 10) : null;
    let res;
    try {
      res = await adminFetch('/api/admin/clubs', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          league_id: league.id, domestic_league_id: domesticLeagueId,
          name_en: inputEn.value, name_he: inputHe.value,
        }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete('teams');
    loadTeamsTab();
  });

  return form;
}

function startRenameClub(club, data, row) {
  row.innerHTML = '';
  const inputEn = document.createElement('input');
  inputEn.type = 'text';
  inputEn.value = club.name_en;
  const inputHe = document.createElement('input');
  inputHe.type = 'text';
  inputHe.value = club.name_he;
  inputHe.dir = 'rtl';
  const leagueSelect = buildLeagueSelect(data.leagues, null, false);
  leagueSelect.value = club.league_id;
  let domesticSelect = buildLeagueSelect(data.leagues, club.league_id, true);
  domesticSelect.value = club.domestic_league_id || '';

  leagueSelect.addEventListener('change', () => {
    const chosen = parseInt(leagueSelect.value, 10);
    const rebuilt = buildLeagueSelect(data.leagues, chosen, true);
    domesticSelect.replaceWith(rebuilt);
    domesticSelect = rebuilt;
  });

  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.textContent = t('adminSave');
  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';

  [inputEn, inputHe, leagueSelect, domesticSelect, saveBtn, errorSpan].forEach(el => row.appendChild(el));
  inputEn.focus();

  saveBtn.addEventListener('click', async () => {
    errorSpan.textContent = '';
    const domesticLeagueId = domesticSelect.value ? parseInt(domesticSelect.value, 10) : null;
    let res;
    try {
      res = await adminFetch(`/api/admin/clubs/${club.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          league_id: parseInt(leagueSelect.value, 10), domestic_league_id: domesticLeagueId,
          name_en: inputEn.value, name_he: inputHe.value,
        }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete('teams');
    loadTeamsTab();
  });
}

async function deleteClub(club) {
  if (!confirm(t('adminConfirmDeleteParty').replace('{name}', localizedName(club)))) return;
  let res;
  try {
    res = await adminFetch(`/api/admin/clubs/${club.id}`, { method: 'DELETE' });
  } catch (err) {
    alert(t('adminSomethingWrong'));
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    alert(body.error || t('adminSomethingWrong'));
    return;
  }
  optionsData = null;
  loadedTabs.delete('teams');
  loadTeamsTab();
}

function startRenameLeague(league, header) {
  const nameSpan = header.querySelector('.party-name');
  const inputEn = document.createElement('input');
  inputEn.type = 'text';
  inputEn.value = league.name_en;
  const inputHe = document.createElement('input');
  inputHe.type = 'text';
  inputHe.value = league.name_he;
  inputHe.dir = 'rtl';
  nameSpan.replaceWith(inputEn);
  inputEn.after(inputHe);

  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.textContent = t('adminSave');
  inputHe.after(saveBtn);
  inputEn.focus();

  saveBtn.addEventListener('click', async () => {
    const errorSpan = header.querySelector('.row-error');
    errorSpan.textContent = '';
    let res;
    try {
      res = await adminFetch(`/api/admin/leagues/${league.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name_en: inputEn.value, name_he: inputHe.value }),
      });
    } catch (err) {
      errorSpan.textContent = t('adminSomethingWrong');
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || t('adminSomethingWrong');
      return;
    }
    optionsData = null;
    loadedTabs.delete('teams');
    loadTeamsTab();
  });
}

async function deleteLeague(league) {
  if (!confirm(t('adminConfirmDeleteParty').replace('{name}', localizedName(league)))) return;
  let res;
  try {
    res = await adminFetch(`/api/admin/leagues/${league.id}`, { method: 'DELETE' });
  } catch (err) {
    alert(t('adminSomethingWrong'));
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    alert(body.error || t('adminSomethingWrong'));
    return;
  }
  optionsData = null;
  loadedTabs.delete('teams');
  loadTeamsTab();
}

document.getElementById('league-add-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const inputEn = document.getElementById('league-add-input-en');
  const inputHe = document.getElementById('league-add-input-he');
  const errorEl = document.getElementById('league-form-error');
  errorEl.textContent = '';
  let res;
  try {
    res = await adminFetch('/api/admin/leagues', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name_en: inputEn.value, name_he: inputHe.value }),
    });
  } catch (err) {
    errorEl.textContent = t('adminSomethingWrong');
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    errorEl.textContent = body.error || t('adminSomethingWrong');
    return;
  }
  inputEn.value = '';
  inputHe.value = '';
  optionsData = null;
  loadedTabs.delete('teams');
  loadTeamsTab();
});

function previousPartyName(data, id) {
  if (id === null) return t('adminDidNotVote');
  const p = data.previous_parties.find(p => p.id === id);
  return p ? localizedName(p) : `#${id}`;
}

function upcomingPartyNames(data, ids) {
  if (!ids.length) return t('adminUndecided');
  return ids.map(id => {
    const p = data.upcoming_parties.find(p => p.id === id);
    return p ? localizedName(p) : `#${id}`;
  }).join(', ');
}

async function loadVotesTab() {
  const data = await getOptionsData();
  let res;
  try {
    res = await adminFetch('/api/admin/votes');
  } catch (err) {
    return;
  }
  if (res === null || !res.ok) return;
  const { votes } = await res.json();
  lastVotesData = votes.slice().reverse();
  renderVotesTable(data, lastVotesData);
}

function renderVotesTable(data, votes) {
  const container = document.getElementById('votes-table-container');
  container.innerHTML = '';

  const table = document.createElement('table');
  table.className = 'votes-table';

  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  [t('adminColId'), t('adminColCreated'), t('adminColLeague'), t('adminColClub'), t('adminColPrevious'), t('adminColUpcoming'), ''].forEach(text => {
    const th = document.createElement('th');
    th.textContent = text;
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);
  table.appendChild(thead);

  const tbody = document.createElement('tbody');
  votes.forEach(v => {
    const tr = document.createElement('tr');
    [
      v.id,
      v.created_at,
      leagueName(data, v.league_id),
      clubName(data, v.club_id),
      previousPartyName(data, v.previous_party_id),
      upcomingPartyNames(data, v.upcoming_party_ids),
    ].forEach(text => {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    });

    const actionTd = document.createElement('td');
    const deleteBtn = document.createElement('button');
    deleteBtn.type = 'button';
    deleteBtn.textContent = t('adminDelete');
    deleteBtn.addEventListener('click', async () => {
      if (!confirm(t('adminConfirmDeleteVote').replace('{id}', v.id))) return;
      let res;
      try {
        res = await adminFetch(`/api/admin/votes/${v.id}`, { method: 'DELETE' });
      } catch (err) {
        alert(t('adminSomethingWrong'));
        return;
      }
      if (res === null) return;
      if (!res.ok) {
        alert(t('adminSomethingWrong'));
        return;
      }
      tr.remove();
    });
    actionTd.appendChild(deleteBtn);
    tr.appendChild(actionTd);

    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  container.appendChild(table);
}

document.addEventListener('voteball:langchange', () => {
  if (optionsData) {
    ['previous', 'upcoming'].forEach(type => {
      if (!loadedTabs.has(type)) return;
      const container = document.getElementById(`${type}-party-list`);
      const hasOpenReassignForm = container.querySelector('.reassign-form') !== null;
      const hasOpenRename = Array.from(container.querySelectorAll('.party-row')).some(
        row => openRenameKeys.has(`${type}:${row.dataset.partyId}`)
      );
      if (hasOpenRename || hasOpenReassignForm) return; // leave in-progress edits/open forms alone
      renderPartyList(type, optionsData[partyListKey(type)]);
    });
  }
  if (optionsData && lastVotesData && loadedTabs.has('votes')) {
    renderVotesTable(optionsData, lastVotesData);
  }
});
