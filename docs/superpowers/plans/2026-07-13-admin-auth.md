# Admin Authentication (Username/Password) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the admin UI's static shared secret (`X-Admin-Secret` header vs. `ADMIN_SECRET` env
var) with a real username/password login that issues a signed, expiring session token — the password
is never stored in plain text.

**Architecture:** `POST /api/admin/login` checks a username and a `werkzeug`-hashed password, then
mints a 12-hour signed token (`itsdangerous.URLSafeTimedSerializer`) that every other admin route
verifies via a rewritten `require_admin` decorator (same name, same 8 call sites, only its internals
change). No new dependencies — both `werkzeug` and `itsdangerous` already ship with Flask. No new DB
table — credentials live in three env vars, provisioned the same way `ADMIN_SECRET` is today.

**Tech Stack:** Flask 3.1, `werkzeug.security` (hashing), `itsdangerous` (signed tokens) — both
already-installed Flask dependencies; vanilla JS on the frontend, no new libraries.

## Global Constraints

- Single admin account — no multi-user support, no account management UI.
- No new Python dependencies (`werkzeug`, `itsdangerous` are already present via Flask).
- No server-side session store or revocation — tokens are stateless and self-expiring (12h); logout is
  client-side only.
- No rate limiting on the login endpoint.
- The real, deployed `ansible-project/inventories/voteball/group_vars/all/secrets.yml` is **never**
  edited by any task in this plan — it's vault-encrypted and the real `.vault_pass` isn't present in
  this worktree. Tasks touch only `secrets.yml.example` and other templates/docs. Rotating the real
  secret is a manual step for the user afterward (see Task 5).
- This plan revises code already built and merged by an earlier plan
  (`docs/superpowers/plans/2026-07-13-admin-ui.md`, 10 of 13 tasks complete) — `admin.html`'s secret
  gate (from that plan's Task 7) and `admin.js`'s gate logic (from that plan's Task 8) are being
  edited, not created fresh. Tasks 3 and 4 below say exactly what to change and nothing else.
- Frontend never uses `innerHTML` to render API/admin-derived data — `createElement`/`textContent`
  only (unaffected by this plan — no new data rendering, just auth plumbing).

---

## Task 1: Backend auth core — login endpoint, token verification, migrate existing tests

**Files:**
- Modify: `ansible-project/roles/backend/files/backend/app.py`
- Modify: `ansible-project/roles/backend/files/backend/tests/conftest.py`
- Modify: `ansible-project/roles/backend/files/backend/tests/test_app.py`

**Interfaces:**
- Produces: `POST /api/admin/login` (unauthenticated) — body `{"username": str, "password": str}` →
  `200 {"token": str}` on success, `401 {"error": "invalid username or password"}` on any failure.
  `require_admin` (same decorator name/call sites) now verifies `Authorization: Bearer <token>`
  instead of `X-Admin-Secret`. `app.ADMIN_USERNAME`, `app.ADMIN_PASSWORD_HASH`,
  `app.ADMIN_SESSION_SECRET`, `app._admin_token_serializer`, `app.ADMIN_TOKEN_MAX_AGE` (module-level
  attributes, used directly by this task's own expired-token test). A new `admin_headers` pytest
  fixture in `conftest.py` (`conn` fixture unaffected).
- Consumes: nothing new from other tasks.

This task is necessarily one atomic change: `require_admin`'s rewrite immediately breaks every
existing test that sends `X-Admin-Secret`, and `app.py`'s new module-level env var reads immediately
break test collection unless `conftest.py` changes in the same step. There will be an intentional
red state partway through (Step 5) — that's expected, not a mistake — followed by the migration that
brings the whole suite back to green before committing.

- [ ] **Step 1: Write the new failing tests**

Append to `tests/test_app.py`:

```python
def test_admin_login_succeeds_with_correct_credentials(client):
    resp = client.post('/api/admin/login', json={'username': 'testadmin', 'password': 'test-admin-password'})
    assert resp.status_code == 200
    body = resp.get_json()
    assert 'token' in body
    assert isinstance(body['token'], str)
    assert len(body['token']) > 0


def test_admin_login_rejects_wrong_password(client):
    resp = client.post('/api/admin/login', json={'username': 'testadmin', 'password': 'wrong'})
    assert resp.status_code == 401
    assert resp.get_json() == {'error': 'invalid username or password'}


def test_admin_login_rejects_wrong_username(client):
    resp = client.post('/api/admin/login', json={'username': 'nobody', 'password': 'test-admin-password'})
    assert resp.status_code == 401
    assert resp.get_json() == {'error': 'invalid username or password'}


def test_admin_login_rejects_missing_username(client):
    resp = client.post('/api/admin/login', json={'password': 'test-admin-password'})
    assert resp.status_code == 401
    assert resp.get_json() == {'error': 'invalid username or password'}


def test_admin_login_rejects_missing_password(client):
    resp = client.post('/api/admin/login', json={'username': 'testadmin'})
    assert resp.status_code == 401
    assert resp.get_json() == {'error': 'invalid username or password'}


def test_require_admin_rejects_missing_authorization_header(client):
    resp = client.get('/api/admin/votes')
    assert resp.status_code == 401


def test_require_admin_rejects_non_bearer_header(client):
    resp = client.get('/api/admin/votes', headers={'Authorization': 'Basic dGVzdA=='})
    assert resp.status_code == 401


def test_require_admin_rejects_token_with_bad_signature(client):
    resp = client.get('/api/admin/votes', headers={'Authorization': 'Bearer not-a-real-token'})
    assert resp.status_code == 401


def test_require_admin_rejects_expired_token(client):
    import app as app_module
    from unittest.mock import patch
    import time as time_module

    with patch.object(time_module, 'time', return_value=time_module.time() - 100000):
        old_token = app_module._admin_token_serializer.dumps(app_module.ADMIN_USERNAME)

    resp = client.get('/api/admin/votes', headers={'Authorization': f'Bearer {old_token}'})
    assert resp.status_code == 401
```

- [ ] **Step 2: Run the new tests to verify they fail for the right reason**

Run: `cd ansible-project/roles/backend/files/backend && source .venv/bin/activate && python -m pytest tests/test_app.py -k "admin_login or require_admin_rejects" -v`

Expected: the 5 `test_admin_login_*` tests FAIL (404 — the route doesn't exist yet).
`test_require_admin_rejects_expired_token` FAILS with `AttributeError` (`app` module has no
`_admin_token_serializer`/`ADMIN_USERNAME` attribute under that name yet — today's `app.py` uses
`ADMIN_SECRET`). The other three `test_require_admin_rejects_*` tests may already PASS at this point
— today's `require_admin` returns 401 for any request missing a valid `X-Admin-Secret` header
regardless of what's in `Authorization`, so these three don't discriminate old-vs-new behavior on
their own. That's fine: they still pin the desired final behavior and will catch a regression later.

- [ ] **Step 3: Update `conftest.py`'s env vars and add the `admin_headers` fixture**

In `tests/conftest.py`, replace:
```python
os.environ.setdefault('ADMIN_SECRET', 'test-admin-secret')
```
with:
```python
os.environ.setdefault('ADMIN_USERNAME', 'testadmin')
os.environ.setdefault('ADMIN_PASSWORD_HASH', generate_password_hash('test-admin-password'))
os.environ.setdefault('ADMIN_SESSION_SECRET', 'test-session-secret-not-for-production')
```
Add the import near the top of the file, alongside the existing `import psycopg2`:
```python
from werkzeug.security import generate_password_hash
```
Add this fixture after the existing `client` fixture, at the end of the file:
```python
@pytest.fixture
def admin_headers(client):
    resp = client.post('/api/admin/login', json={'username': 'testadmin', 'password': 'test-admin-password'})
    token = resp.get_json()['token']
    return {'Authorization': f'Bearer {token}'}
```

- [ ] **Step 4: Rewrite `app.py`'s auth core**

Replace:
```python
import uuid
import os
from functools import wraps
from flask import Flask, jsonify, request, make_response
import db
import queries

app = Flask(__name__)

ADMIN_SECRET = os.environ['ADMIN_SECRET']


def require_admin(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if request.headers.get('X-Admin-Secret') != ADMIN_SECRET:
            return jsonify({'error': 'unauthorized'}), 401
        return f(*args, **kwargs)
    return wrapper
```
with:
```python
import uuid
import os
from functools import wraps
from flask import Flask, jsonify, request, make_response
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired
from werkzeug.security import check_password_hash
import db
import queries

app = Flask(__name__)

ADMIN_USERNAME = os.environ['ADMIN_USERNAME']
ADMIN_PASSWORD_HASH = os.environ['ADMIN_PASSWORD_HASH']
ADMIN_SESSION_SECRET = os.environ['ADMIN_SESSION_SECRET']

_admin_token_serializer = URLSafeTimedSerializer(ADMIN_SESSION_SECRET, salt='admin-session')
ADMIN_TOKEN_MAX_AGE = 12 * 60 * 60  # 12 hours, in seconds


def require_admin(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'unauthorized'}), 401
        token = auth_header[len('Bearer '):]
        try:
            username = _admin_token_serializer.loads(token, max_age=ADMIN_TOKEN_MAX_AGE)
        except (BadSignature, SignatureExpired):
            return jsonify({'error': 'unauthorized'}), 401
        if username != ADMIN_USERNAME:
            return jsonify({'error': 'unauthorized'}), 401
        return f(*args, **kwargs)
    return wrapper
```

Add the login route. Place it directly after the `results()` route (i.e., immediately before
`@app.route('/api/admin/upcoming-parties', methods=['POST'])`):
```python
@app.route('/api/admin/login', methods=['POST'])
def admin_login():
    body = request.get_json(force=True, silent=True) or {}
    username = body.get('username', '')
    password = body.get('password', '')

    username_ok = username == ADMIN_USERNAME
    password_ok = check_password_hash(ADMIN_PASSWORD_HASH, password)
    if not (username_ok and password_ok):
        return jsonify({'error': 'invalid username or password'}), 401

    token = _admin_token_serializer.dumps(ADMIN_USERNAME)
    return jsonify({'token': token})
```
Note `check_password_hash` always runs even when `username_ok` is already `False` — do not
short-circuit this with an early return on username mismatch; that would make the endpoint
measurably faster for a wrong username than a wrong password, leaking which one was true via timing.

- [ ] **Step 5: Run the new tests, then the full suite, to see the expected transition**

Run: `python -m pytest tests/test_app.py -k "admin_login or require_admin_rejects" -v`
Expected: all 9 PASS now.

Run: `python -m pytest tests/ -v`
Expected: the 9 new tests pass, but roughly 16 previously-passing tests now FAIL — they still send
`X-Admin-Secret`, which `require_admin` no longer checks, so every admin action they attempt gets a
401 instead of succeeding. **This is expected** — it's exactly the tests Step 6 migrates.

- [ ] **Step 6: Migrate every existing test that authenticates as admin**

Apply this exact two-part change to each function listed below:
1. Add `admin_headers` as the last parameter in the function's signature.
2. Change its line `headers = {'X-Admin-Secret': 'test-admin-secret'}` to `headers = admin_headers`.

Nothing else in any of these functions changes — every other line (assertions, request bodies, etc.)
stays exactly as it is today.

Worked example — `test_upcoming_party_admin_crud`, change:
```python
def test_upcoming_party_admin_crud(client):
    headers = {'X-Admin-Secret': 'test-admin-secret'}
```
to:
```python
def test_upcoming_party_admin_crud(client, admin_headers):
    headers = admin_headers
```

Apply the identical transformation to these 15 remaining functions (signature shown as it exists
today — add `admin_headers` as the last parameter of each, and change its
`headers = {'X-Admin-Secret': 'test-admin-secret'}` line to `headers = admin_headers`):

- `test_admin_votes_list_returns_votes_with_valid_secret(client, conn)`
- `test_previous_party_admin_crud(client)`
- `test_create_upcoming_party_duplicate_name_returns_409(client)`
- `test_rename_upcoming_party_duplicate_name_returns_409(client)`
- `test_create_previous_party_duplicate_name_returns_409(client)`
- `test_rename_previous_party_duplicate_name_returns_409(client)`
- `test_delete_upcoming_party_blocked_when_referenced_by_votes(client, conn)`
- `test_delete_previous_party_blocked_when_referenced_by_votes(client, conn)`
- `test_previous_party_reassign_moves_votes_and_updates_count(client, conn)`
- `test_previous_party_reassign_rejects_equal_source_and_target(client, conn)`
- `test_previous_party_reassign_rejects_nonexistent_target(client, conn)`
- `test_upcoming_party_reassign_moves_votes_and_updates_count(client, conn)`
- `test_upcoming_party_reassign_rejects_equal_source_and_target(client, conn)`
- `test_upcoming_party_reassign_rejects_nonexistent_target(client, conn)`

One function has a mixed body — a no-auth 401 check followed by an authenticated section — only its
authenticated section's `headers` line changes, and its no-auth check (the `client.delete(...)` call
with no `headers=` argument, asserting `401`) stays untouched:
```python
def test_admin_votes_delete_requires_admin_secret_and_handles_not_found(client, conn):
    # ...unchanged...
    resp = client.delete(f'/api/admin/votes/{vote_id}')
    assert resp.status_code == 401              # <-- leave this section as-is

    headers = {'X-Admin-Secret': 'test-admin-secret'}   # <-- only this line changes
    resp = client.delete(f'/api/admin/votes/{vote_id}', headers=headers)
    assert resp.status_code == 204
    # ...unchanged...
```
becomes (function signature also gains `admin_headers`):
```python
def test_admin_votes_delete_requires_admin_secret_and_handles_not_found(client, conn, admin_headers):
    # ...unchanged...
    resp = client.delete(f'/api/admin/votes/{vote_id}')
    assert resp.status_code == 401

    headers = admin_headers
    resp = client.delete(f'/api/admin/votes/{vote_id}', headers=headers)
    assert resp.status_code == 204
    # ...unchanged...
```

- [ ] **Step 7: Rename the no-auth-required tests for accuracy**

These five test names reference "admin_secret," which no longer exists as a concept. Their bodies
need no logic changes (they test the missing-auth 401 case, which behaves identically under the new
decorator) — rename only:

- `test_admin_votes_list_requires_admin_secret(client):` →
  `test_admin_votes_list_requires_authentication(client):`
- `test_previous_party_admin_routes_require_admin_secret(client):` →
  `test_previous_party_admin_routes_require_authentication(client):`
- `test_previous_party_reassign_requires_admin_secret(client):` →
  `test_previous_party_reassign_requires_authentication(client):`
- `test_upcoming_party_reassign_requires_admin_secret(client):` →
  `test_upcoming_party_reassign_requires_authentication(client):`

One more rename, on the mixed-body function Step 6 already gave a 3-parameter signature to — match
against that current (post-Step-6) signature, not the original 2-parameter one:
`test_admin_votes_delete_requires_admin_secret_and_handles_not_found(client, conn, admin_headers):` →
`test_admin_votes_delete_requires_authentication_and_handles_not_found(client, conn, admin_headers):`

- [ ] **Step 8: Run the full suite — expect all green**

Run: `python -m pytest tests/ -v`
Expected: 62 passed (53 from before this task, plus the 9 new ones from Step 1; the ~16 migrated
tests are the same tests, not new ones, so they don't add to the count).

- [ ] **Step 9: Commit**

```bash
git add ansible-project/roles/backend/files/backend/app.py ansible-project/roles/backend/files/backend/tests/conftest.py ansible-project/roles/backend/files/backend/tests/test_app.py
git commit -m "Replace static admin secret with username/password login + signed session tokens"
```

---

## Task 2: Password-hashing helper script

**Files:**
- Create: `ansible-project/roles/backend/files/backend/scripts/hash_admin_password.py`

**Interfaces:**
- Produces: a standalone CLI tool (not imported by the app) that prints a `werkzeug` password hash to
  stdout, for pasting into `secrets.yml` as `admin_password_hash`. Not covered by pytest — it's an
  operator tool, same category as the existing `scripts/find-latest-snapshot.sh` /
  `scripts/generate-inventory.sh`, verified by running it once, not by an automated test.

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/env python3
"""Print a werkzeug password hash for use as ADMIN_PASSWORD_HASH in secrets.yml.

Usage: python scripts/hash_admin_password.py
Prompts for a password (not echoed), prints the resulting hash to stdout.
"""
import getpass
from werkzeug.security import generate_password_hash

if __name__ == '__main__':
    password = getpass.getpass('Admin password: ')
    print(generate_password_hash(password))
```

- [ ] **Step 2: Verify it runs and produces a hash that round-trips**

Run (from `ansible-project/roles/backend/files/backend`, with the venv active):
```bash
echo 'a-test-password' | python scripts/hash_admin_password.py
```
Expected: prints a single line starting with `scrypt:` (werkzeug's current default hashing method) —
`getpass` falls back to reading a line from stdin when it isn't attached to a real terminal (as with
the piped `echo` above), with a warning printed to stderr; that's expected in this non-interactive
check, not a bug.

Then confirm the printed hash actually validates the password it was generated from:
```bash
python -c "
import sys
from werkzeug.security import check_password_hash
h = sys.argv[1]
print(check_password_hash(h, 'a-test-password'))
print(check_password_hash(h, 'wrong-password'))
" "$(echo 'a-test-password' | python scripts/hash_admin_password.py 2>/dev/null)"
```
Expected: prints `True` then `False`.

- [ ] **Step 3: Commit**

```bash
git add ansible-project/roles/backend/files/backend/scripts/hash_admin_password.py
git commit -m "Add hash_admin_password.py helper for generating ADMIN_PASSWORD_HASH"
```

---

## Task 3: `admin.html` — login form and logout button

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/admin.html`

**Interfaces:**
- Produces: `#username-input`, `#password-input` (replacing the single `#secret-input` from the prior
  admin-ui plan's Task 7), `#logout-button` (new). `#secret-gate`, `#secret-form`, `#secret-error`
  keep their existing IDs unchanged. Consumed by Task 4's `admin.js` rewrite.

- [ ] **Step 1: Replace the secret-only form with a username/password login form**

Replace:
```html
  <div id="secret-gate">
    <form id="secret-form">
      <label>Admin secret: <input type="password" id="secret-input" required></label>
      <button type="submit">Enter</button>
      <p class="error" id="secret-error"></p>
    </form>
  </div>
```
with:
```html
  <div id="secret-gate">
    <form id="secret-form">
      <label>Username: <input type="text" id="username-input" required autocomplete="username"></label>
      <label>Password: <input type="password" id="password-input" required autocomplete="current-password"></label>
      <button type="submit">Log in</button>
      <p class="error" id="secret-error"></p>
    </form>
  </div>
```

- [ ] **Step 2: Add a "Log out" button to the tab bar**

Replace:
```html
    <div class="tab-bar">
      <button type="button" class="tab-button active" data-tab="previous">Previous Parties</button>
      <button type="button" class="tab-button" data-tab="upcoming">Upcoming Parties</button>
      <button type="button" class="tab-button" data-tab="votes">Votes</button>
    </div>
```
with:
```html
    <div class="tab-bar">
      <button type="button" class="tab-button active" data-tab="previous">Previous Parties</button>
      <button type="button" class="tab-button" data-tab="upcoming">Upcoming Parties</button>
      <button type="button" class="tab-button" data-tab="votes">Votes</button>
      <button type="button" id="logout-button">Log out</button>
    </div>
```

- [ ] **Step 3: Commit**

```bash
git add ansible-project/roles/frontend/files/nginx/admin.html
git commit -m "Replace admin.html's secret field with a username/password login form and add Log out"
```

(No manual browser verification for this task alone — the page won't function correctly until Task 4
updates `admin.js` to match these new element IDs. Verification happens together in Task 4's step.)

---

## Task 4: `admin.js` — token-based auth, login, logout

**Files:**
- Modify: `ansible-project/roles/frontend/files/nginx/admin.js`

**Interfaces:**
- Consumes: `#username-input`, `#password-input`, `#logout-button` from Task 3.
- Produces: `ADMIN_TOKEN_KEY` (renamed from `ADMIN_SECRET_KEY`), `adminHeaders()` now returns
  `Authorization: Bearer <token>`, `tryEnterWithStoredToken()` (renamed from
  `tryEnterWithStoredSecret`). All party-tab, reassign, and (once built) votes-tab code from the prior
  admin-ui plan is untouched — only the auth-related constant, functions, and event listeners at the
  top and bottom of the file change.

- [ ] **Step 1: Rename the storage key and update `adminHeaders`/`adminFetch`**

Replace:
```javascript
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
```
with:
```javascript
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
```

- [ ] **Step 2: Replace the login submit handler and the stored-session check**

Replace:
```javascript
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
```
with:
```javascript
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
```

- [ ] **Step 3: Manually verify end-to-end**

There's no automated frontend test suite. Set up the local dev loop (same pattern used throughout the
prior admin-ui plan):

```bash
# Test Postgres, if not already running
docker run -d --name voteball-test-db -e POSTGRES_PASSWORD=test -p 5432:5432 postgres:17

# Backend — note the new env vars replacing ADMIN_SECRET
cd ansible-project/roles/backend/files/backend
source .venv/bin/activate
DB_HOST=localhost DB_PASS=test DB_SSLMODE=disable \
  ADMIN_USERNAME=devadmin \
  ADMIN_PASSWORD_HASH="$(python -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('dev-password'))")" \
  ADMIN_SESSION_SECRET=dev-session-secret \
  SNS_TOPIC=arn:aws:sns:il-central-1:000000000000:test AWS_REGION=il-central-1 \
  python app.py &
```

Throwaway nginx proxy (same as the prior plan's recipe):
```bash
cat > /tmp/voteball-dev-nginx.conf <<'EOF'
server {
    listen 8080;
    location / { root /usr/share/nginx/html; index index.html; try_files $uri $uri/ =404; }
    location /api/ { proxy_pass http://host.docker.internal:5000; }
}
EOF
docker run -d --name voteball-dev-nginx -p 8080:8080 \
  --add-host=host.docker.internal:host-gateway \
  -v "$(pwd)/../../../../frontend/files/nginx:/usr/share/nginx/html:ro" \
  -v /tmp/voteball-dev-nginx.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:alpine
```

Drive `http://localhost:8080/admin.html` (Playwright MCP needs Google Chrome and may be unavailable —
if so, drive a real Chromium browser directly via the `playwright` npm library instead, cleaning up
any npm artifacts before finishing):
- Wrong username or wrong password → "Incorrect username or password.", tabs stay hidden.
- Correct credentials (`devadmin` / `dev-password`) → tabs appear.
- Refresh the page → session persists (skips the login form) without re-entering credentials.
- Click "Log out" → login form re-appears; a subsequent tab click doesn't reveal admin content.
- Log in again, exercise one existing feature (e.g. add a party) to confirm `adminFetch`/token
  plumbing still works for the previously-built party CRUD code.

Tear down: stop/remove `voteball-dev-nginx`, kill the backend background job. Leave
`voteball-test-db` running (shared with other work).

- [ ] **Step 4: Commit**

```bash
git add ansible-project/roles/frontend/files/nginx/admin.js
git commit -m "Switch admin.js from raw-secret storage to login/token auth, add logout"
```

---

## Task 5: Deployment templates and docs

**Files:**
- Modify: `ansible-project/inventories/voteball/group_vars/all/secrets.yml.example`
- Modify: `ansible-project/roles/k3s/tasks/main.yml`
- Modify: `docs/deploy.md`

**Interfaces:** none (templates/docs only — no code consumes these directly; the real `secrets.yml`
is not touched, per Global Constraints).

- [ ] **Step 1: Update `secrets.yml.example`**

Replace:
```
db_pass: your_rds_master_password_here
admin_secret: your_admin_secret_here
```
with:
```
db_pass: your_rds_master_password_here
admin_username: your_admin_username_here
admin_password_hash: your_admin_password_hash_here   # generate via: cd ansible-project/roles/backend/files/backend && source .venv/bin/activate && python scripts/hash_admin_password.py
admin_session_secret: your_random_session_secret_here   # generate via: openssl rand -hex 32
```
Also replace the comment line describing what to edit:
```
#   # edit secrets.yml: set db_pass (matches terraform/voteball.tfvars) and admin_secret
```
with:
```
#   # edit secrets.yml: set db_pass (matches terraform/voteball.tfvars), admin_username,
#   # admin_password_hash, and admin_session_secret
```

- [ ] **Step 2: Update the k3s role's Secret manifest**

In `ansible-project/roles/k3s/tasks/main.yml`, replace:
```yaml
        DB_USER: "{{ db_user | default('postgres') | b64encode }}"
        DB_PASS: "{{ db_pass | b64encode }}"
        ADMIN_SECRET: "{{ admin_secret | b64encode }}"
```
with:
```yaml
        DB_USER: "{{ db_user | default('postgres') | b64encode }}"
        DB_PASS: "{{ db_pass | b64encode }}"
        ADMIN_USERNAME: "{{ admin_username | b64encode }}"
        ADMIN_PASSWORD_HASH: "{{ admin_password_hash | b64encode }}"
        ADMIN_SESSION_SECRET: "{{ admin_session_secret | b64encode }}"
```

- [ ] **Step 3: Update `docs/deploy.md`**

Replace:
```
# edit secrets.yml: db_pass (must match voteball.tfvars' db_password), admin_secret (openssl rand -hex 32)
```
with:
```
# edit secrets.yml: db_pass (must match voteball.tfvars' db_password), admin_username,
# admin_password_hash (generate via ansible-project/roles/backend/files/backend/scripts/hash_admin_password.py),
# admin_session_secret (openssl rand -hex 32)
```

Directly after that fenced code block, before the "Back up these 4 files..." paragraph, add a callout
for anyone redeploying an existing installation. Replace:
~~~
cd ..
```

**Back up these 4 files somewhere other than this disk** (a password manager entry
is enough — they're all small text/key files): `Voteball-EC2-pem.pem`,
~~~
with:
~~~
cd ..
```

**Redeploying an existing installation?** This admin-auth migration is a breaking change: the
backend container now requires `ADMIN_USERNAME`/`ADMIN_PASSWORD_HASH`/`ADMIN_SESSION_SECRET` and no
longer reads `ADMIN_SECRET` at all. Before the next `ansible-playbook` run, edit the real
`secrets.yml` (`ansible-vault edit inventories/voteball/group_vars/all/secrets.yml
--vault-password-file .vault_pass`) to replace `admin_secret` with the three new keys — otherwise the
backend pod will crash-loop on missing env vars.

**Back up these 4 files somewhere other than this disk** (a password manager entry
is enough — they're all small text/key files): `Voteball-EC2-pem.pem`,
~~~

- [ ] **Step 4: Commit**

```bash
git add ansible-project/inventories/voteball/group_vars/all/secrets.yml.example ansible-project/roles/k3s/tasks/main.yml docs/deploy.md
git commit -m "Update deployment templates and docs for username/password admin auth"
```

---

## Task 6: Document the new auth model in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the `require_admin` description**

Replace:
```
Admin endpoints (`/api/admin/...`) are protected by the `require_admin` decorator in `app.py`, which
checks the `X-Admin-Secret` header against the `ADMIN_SECRET` env var. Reuse this decorator for any
new admin route — don't hand-roll the check.
```
with:
```
Admin endpoints (`/api/admin/...`) are protected by the `require_admin` decorator in `app.py`, which
verifies an `Authorization: Bearer <token>` header — a signed, 12-hour-expiring token
(`itsdangerous.URLSafeTimedSerializer`) issued by `POST /api/admin/login` after checking a username
and `werkzeug`-hashed password (`ADMIN_USERNAME`/`ADMIN_PASSWORD_HASH`/`ADMIN_SESSION_SECRET` env
vars). Reuse this decorator for any new admin route — don't hand-roll the check.
```

- [ ] **Step 2: Update the API surface table**

Replace each of these six rows:
```
| `/api/admin/previous-parties` | POST | `X-Admin-Secret` | create |
```
```
| `/api/admin/previous-parties/<id>` | PATCH/DELETE | `X-Admin-Secret` | rename/remove |
```
```
| `/api/admin/upcoming-parties` | POST | `X-Admin-Secret` | create |
```
```
| `/api/admin/upcoming-parties/<id>` | PATCH/DELETE | `X-Admin-Secret` | rename/remove |
```
```
| `/api/admin/votes` | GET | `X-Admin-Secret` | list all votes (no `cookie_token` in the response) |
```
```
| `/api/admin/votes/<id>` | DELETE | `X-Admin-Secret` | remove one vote; cascades to its `vote_upcoming_parties` rows |
```
with (same six rows, `Auth` column changed from `` `X-Admin-Secret` `` to `` Bearer token ``, nothing
else changed):
```
| `/api/admin/previous-parties` | POST | Bearer token | create |
```
```
| `/api/admin/previous-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove |
```
```
| `/api/admin/upcoming-parties` | POST | Bearer token | create |
```
```
| `/api/admin/upcoming-parties/<id>` | PATCH/DELETE | Bearer token | rename/remove |
```
```
| `/api/admin/votes` | GET | Bearer token | list all votes (no `cookie_token` in the response) |
```
```
| `/api/admin/votes/<id>` | DELETE | Bearer token | remove one vote; cascades to its `vote_upcoming_parties` rows |
```

Then add a new row for the login endpoint itself, directly after the `/api/results` row (i.e., right
before `/api/admin/previous-parties`'s row). Replace:
```
| `/api/results` | GET | none | `?by=club\|league\|id=N` or `?by=party&type=previous\|upcoming&id=N` (the latter also returns a global `crosstab` of the other party type); reads the worker-computed rollup tables |
```
with:
```
| `/api/results` | GET | none | `?by=club\|league\|id=N` or `?by=party&type=previous\|upcoming&id=N` (the latter also returns a global `crosstab` of the other party type); reads the worker-computed rollup tables |
| `/api/admin/login` | POST | none | body `{"username", "password"}`; returns `{"token"}` on success, `401` on any failure |
```

> Note for whoever later executes `docs/superpowers/plans/2026-07-13-admin-ui.md`'s Task 13 (still
> pending as of this plan): that task's own brief was written against the pre-auth-redesign table and
> will add reassign-endpoint rows using `X-Admin-Secret` in its own old_string/new_string text. By the
> time Task 13 runs, this table already says `Bearer token`, not `X-Admin-Secret` — re-derive Task
> 13's exact edits from the table's current state rather than trusting its original brief text
> verbatim.

- [ ] **Step 3: Update the two remaining mentions**

Replace:
```
`ansible-project/inventories/voteball/group_vars/all/secrets.yml` (holds `db_pass`, `admin_secret`) is
```
with:
```
`ansible-project/inventories/voteball/group_vars/all/secrets.yml` (holds `db_pass`, `admin_username`,
`admin_password_hash`, `admin_session_secret`) is
```

Replace:
```
`tests/conftest.py` sets required env vars (`DB_HOST`, `DB_PASS`, `ADMIN_SECRET`, etc.) via
```
with:
```
`tests/conftest.py` sets required env vars (`DB_HOST`, `DB_PASS`, `ADMIN_USERNAME`,
`ADMIN_PASSWORD_HASH`, `ADMIN_SESSION_SECRET`, etc.) via
```

Replace:
```
- Admin auth is a static shared secret in the `X-Admin-Secret` header vs. `ADMIN_SECRET` env var — not
  per-user auth.
```
with:
```
- Admin auth is username/password login (`POST /api/admin/login`) issuing a signed, 12-hour token
  verified via `Authorization: Bearer <token>` — single admin account, password hashed with
  `werkzeug.security`, no server-side session store (rotating `ADMIN_SESSION_SECRET` invalidates all
  outstanding tokens).
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Document username/password admin auth in CLAUDE.md"
```

---

## Task 7: Full end-to-end manual verification pass

**Files:** none (verification only)

- [ ] **Step 1: Run the full backend suite**

```bash
cd ansible-project/roles/backend/files/backend
source .venv/bin/activate
python -m pytest tests/ -v
```
Expected: all 62 tests pass.

- [ ] **Step 2: `helm lint` sanity check**

```bash
helm lint charts/voteball
```
Expected: no errors (this plan doesn't touch the Helm chart itself, only the Ansible role that
renders the Secret manifest — this is a quick regression check, not expected to find anything).

- [ ] **Step 3: `ansible-playbook --syntax-check`**

```bash
cd ansible-project
ansible-playbook --syntax-check site-k3s.yml
```
Expected: passes — confirms Task 5's Jinja template edits didn't break YAML/Jinja syntax.

- [ ] **Step 4: Full manual browser pass**

Repeat Task 4's browser verification (login, wrong credentials, logout, session persistence across
reload) plus a spot-check of the previously-built party CRUD and reassign-votes features to confirm
nothing else regressed. Use the same local dev loop (test Postgres + `python app.py` with the new env
vars + throwaway nginx proxy) as Task 4.

- [ ] **Step 5: Tear down local dev processes**

```bash
docker stop voteball-dev-nginx && docker rm voteball-dev-nginx  # if still running
kill %1  # the python app.py background job, if still running
# leave voteball-test-db running — shared with other work in this repo
```

No commit for this task — it's a verification checkpoint. If anything fails, fix it in the relevant
earlier task's files and re-run the affected steps before considering this plan complete.
