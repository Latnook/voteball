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
  // Per-tab loaders are added here by Tasks 9 (party tabs) and 11 (votes tab).
}

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
