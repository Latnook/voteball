const ADMIN_TOKEN_KEY = 'voteballAdminToken';
let optionsData = null;
const loadedTabs = new Set();

function adminHeaders() {
  return { 'Authorization': 'Bearer ' + (sessionStorage.getItem(ADMIN_TOKEN_KEY) || '') };
}

async function adminFetch(url, options = {}) {
  const headers = Object.assign({}, options.headers, adminHeaders());
  const res = await fetch(url, Object.assign({}, options, { headers }));
  if (res.status === 401) {
    sessionStorage.removeItem(ADMIN_TOKEN_KEY);
    showGate('Session expired — re-enter the secret.');
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
  if (tab === 'previous') loadPartyTab('previous');
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

  const nameSpan = document.createElement('span');
  nameSpan.className = 'party-name';
  nameSpan.textContent = party.name;
  row.appendChild(nameSpan);

  const renameBtn = document.createElement('button');
  renameBtn.type = 'button';
  renameBtn.textContent = 'Rename';
  renameBtn.addEventListener('click', () => startRename(type, party, row));
  row.appendChild(renameBtn);

  const reassignBtn = document.createElement('button');
  reassignBtn.type = 'button';
  reassignBtn.textContent = 'Reassign votes…';
  reassignBtn.addEventListener('click', () => toggleReassignForm(type, party, allParties, row));
  row.appendChild(reassignBtn);

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.textContent = 'Delete';
  deleteBtn.addEventListener('click', () => deleteParty(type, party));
  row.appendChild(deleteBtn);

  const errorSpan = document.createElement('span');
  errorSpan.className = 'row-error';
  row.appendChild(errorSpan);

  return row;
}

function startRename(type, party, row) {
  const nameSpan = row.querySelector('.party-name');
  const input = document.createElement('input');
  input.type = 'text';
  input.value = party.name;
  nameSpan.replaceWith(input);

  const saveBtn = document.createElement('button');
  saveBtn.type = 'button';
  saveBtn.textContent = 'Save';
  input.after(saveBtn);
  input.focus();

  saveBtn.addEventListener('click', async () => {
    const errorSpan = row.querySelector('.row-error');
    errorSpan.textContent = '';

    let res;
    try {
      res = await adminFetch(`${partyEndpoint(type)}/${party.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: input.value }),
      });
    } catch (err) {
      errorSpan.textContent = 'Something went wrong.';
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || 'Something went wrong.';
      return;
    }
    optionsData = null;
    loadedTabs.delete(type);
    loadPartyTab(type);
  });
}

async function deleteParty(type, party) {
  if (!confirm(`Delete "${party.name}"? This cannot be undone.`)) return;

  let res;
  try {
    res = await adminFetch(`${partyEndpoint(type)}/${party.id}`, { method: 'DELETE' });
  } catch (err) {
    alert('Something went wrong.');
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    alert(body.error || 'Something went wrong.');
    return;
  }
  optionsData = null;
  loadedTabs.delete(type);
  loadPartyTab(type);
}

async function addParty(e, type) {
  e.preventDefault();
  const input = document.getElementById(`${type}-party-add-input`);
  const errorEl = document.getElementById(`${type}-party-form-error`);
  errorEl.textContent = '';

  let res;
  try {
    res = await adminFetch(partyEndpoint(type), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: input.value }),
    });
  } catch (err) {
    errorEl.textContent = 'Something went wrong.';
    return;
  }
  if (res === null) return;
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    errorEl.textContent = body.error || 'Something went wrong.';
    return;
  }
  input.value = '';
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
    errorEl.textContent = 'Something went wrong — try again.';
    return;
  }

  if (res.status === 401) {
    errorEl.textContent = 'Incorrect username or password.';
    document.getElementById('password-input').value = '';
    return;
  }
  if (!res.ok) {
    errorEl.textContent = 'Something went wrong — try again.';
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
    opt.textContent = p.name;
    select.appendChild(opt);
  });
  form.appendChild(select);

  const goBtn = document.createElement('button');
  goBtn.type = 'button';
  goBtn.textContent = 'Reassign';
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
      errorSpan.textContent = 'Something went wrong.';
      return;
    }
    if (countRes === null) return;
    if (!countRes.ok) {
      errorSpan.textContent = 'Something went wrong.';
      return;
    }
    const { count } = await countRes.json();
    const targetParty = allParties.find(p => p.id === targetId);
    if (!confirm(`Reassign ${count} votes from "${sourceParty.name}" to "${targetParty.name}"? This cannot be undone.`)) {
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
      errorSpan.textContent = 'Something went wrong.';
      return;
    }
    if (res === null) return;
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      errorSpan.textContent = body.error || 'Something went wrong.';
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
  return l ? l.name : `league #${id}`;
}

function clubName(data, id) {
  if (id === null) return '—';
  const c = data.clubs.find(c => c.id === id);
  return c ? c.name : `club #${id}`;
}

function previousPartyName(data, id) {
  if (id === null) return 'did not vote';
  const p = data.previous_parties.find(p => p.id === id);
  return p ? p.name : `#${id}`;
}

function upcomingPartyNames(data, ids) {
  if (!ids.length) return 'undecided';
  return ids.map(id => {
    const p = data.upcoming_parties.find(p => p.id === id);
    return p ? p.name : `#${id}`;
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
  renderVotesTable(data, votes.slice().reverse());
}

function renderVotesTable(data, votes) {
  const container = document.getElementById('votes-table-container');
  container.innerHTML = '';

  const table = document.createElement('table');
  table.className = 'votes-table';

  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  ['ID', 'Created', 'League', 'Club', 'Previous vote', 'Upcoming vote', ''].forEach(text => {
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
    deleteBtn.textContent = 'Delete';
    deleteBtn.addEventListener('click', async () => {
      if (!confirm(`Delete vote #${v.id}? This cannot be undone.`)) return;
      let res;
      try {
        res = await adminFetch(`/api/admin/votes/${v.id}`, { method: 'DELETE' });
      } catch (err) {
        alert('Something went wrong.');
        return;
      }
      if (res === null) return;
      if (!res.ok) {
        alert('Something went wrong.');
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
