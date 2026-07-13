const ADMIN_SECRET_KEY = 'voteballAdminSecret';
let optionsData = null;
const loadedTabs = new Set();

function adminHeaders() {
  return { 'X-Admin-Secret': sessionStorage.getItem(ADMIN_SECRET_KEY) || '' };
}

async function adminFetch(url, options = {}) {
  const headers = Object.assign({}, options.headers, adminHeaders());
  const res = await fetch(url, Object.assign({}, options, { headers }));
  if (res.status === 401) {
    sessionStorage.removeItem(ADMIN_SECRET_KEY);
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
  // votes case added by Task 11
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
  const value = document.getElementById('secret-input').value;
  const errorEl = document.getElementById('secret-error');
  errorEl.textContent = '';

  let res;
  try {
    res = await fetch('/api/admin/votes', { headers: { 'X-Admin-Secret': value } });
  } catch (err) {
    errorEl.textContent = 'Something went wrong — try again.';
    return;
  }

  if (res.status === 401) {
    errorEl.textContent = 'Incorrect secret.';
    document.getElementById('secret-input').value = '';
    return;
  }
  if (!res.ok) {
    errorEl.textContent = 'Something went wrong — try again.';
    return;
  }

  sessionStorage.setItem(ADMIN_SECRET_KEY, value);
  showContent();
  activateTab('previous');
});

async function tryEnterWithStoredSecret() {
  const stored = sessionStorage.getItem(ADMIN_SECRET_KEY);
  if (!stored) return;
  let res;
  try {
    res = await fetch('/api/admin/votes', { headers: { 'X-Admin-Secret': stored } });
  } catch (err) {
    return;
  }
  if (res.ok) {
    showContent();
    activateTab('previous');
  } else {
    sessionStorage.removeItem(ADMIN_SECRET_KEY);
  }
}

tryEnterWithStoredSecret();

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
