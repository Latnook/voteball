# Admin authentication: username/password login replacing the shared secret

Status: approved
Date: 2026-07-13

## Context

The admin UI (spec: `docs/design/2026-07-13-admin-ui-design.md`) is midway through
implementation — 10 of 13 plan tasks done (backend party-CRUD/reassign endpoints complete; frontend
secret-gate, tab switching, party CRUD, and reassign-votes wiring complete) — all built against the
project's existing admin auth model: a single static secret compared against `ADMIN_SECRET`, sent as
the `X-Admin-Secret` header, documented in `CLAUDE.md` as a deliberate "not per-user auth" constraint.

The user has asked for real credentials instead: a username and password, with the password **not**
stored in plain text anywhere. This is a genuine reversal of that documented constraint, not an
addition — `CLAUDE.md`'s "Key constraints" section will be updated accordingly (Non-goals/Deployment
below). It touches the backend auth layer, the already-built frontend gate, and how the deployed
secret is provisioned.

## Decisions

1. **Single admin account, not multi-user.** One username + one hashed password, matching the
   project's existing "single environment, no multi-instance" simplicity philosophy (see
   `CLAUDE.md`). This replaces the shared secret with real credentials; it does not add account
   management.
2. **Credentials live in three env vars**, provisioned the same way `ADMIN_SECRET` is today (vault-
   encrypted `secrets.yml` → Kubernetes `Secret` → container env): `ADMIN_USERNAME`,
   `ADMIN_PASSWORD_HASH` (a `werkzeug`-generated hash — the raw password is never stored or logged
   anywhere), `ADMIN_SESSION_SECRET` (a random signing key, `openssl rand -hex 32`, same generation
   pattern as the other secrets).
3. **`werkzeug.security` for hashing** (`generate_password_hash`/`check_password_hash`) — already a
   Flask dependency (Flask depends on Werkzeug directly), so this adds no new package. Uses
   `werkzeug`'s modern default (scrypt).
4. **`itsdangerous.URLSafeTimedSerializer` for session tokens** — also already a Flask dependency, so
   this too adds no new package. Stateless: no session table, no server-side revocation list. A
   12-hour expiry is embedded and re-checked on every request via `max_age` at verification time.
   Rotating `ADMIN_SESSION_SECRET` instantly invalidates every outstanding token — a free "log
   everyone out" if ever needed, with nothing to clean up.
5. **No rate limiting on login.** Matches the project's current posture (the static secret has none
   either) and its single-EC2, no-shared-state simplicity. A strong password plus 12h token expiry is
   the actual defense; revisit only if it becomes a real concern.
6. **`require_admin` is rewritten in place, not replaced.** Same decorator name, same 8 existing
   call sites in `app.py` completely unchanged — only its internals change, from an `X-Admin-Secret`
   equality check to `Authorization: Bearer <token>` verification. This keeps the blast radius of the
   change to the decorator's body, the new login route, and env var setup.
7. **Login endpoint always runs the password hash check**, even when the username is wrong, rather
   than short-circuiting — `check_password_hash` (scrypt) is deliberately slow, so returning early on
   a bad username would make the login endpoint measurably faster for wrong-username requests than
   wrong-password ones, leaking which one was true via timing. Both checks always run; the response
   is identical (`401 {"error": "invalid username or password"}`) either way.
8. **Frontend gate becomes a real login form** — two fields (username, password) replacing the single
   password field already built in Task 7/8's HTML and JS. This revises already-completed, reviewed
   commits on this branch, not just adds new code; the implementation plan must say so explicitly so
   whoever executes it understands they're editing shipped work, not building from a blank slate.
9. **A new "Log out" button**, absent from the current design, since there's now a real credential
   worth letting the user actively clear rather than just closing the tab. Purely client-side (clears
   the stored token, re-shows the gate) since tokens are stateless — no server endpoint needed.
10. **The real deployed `secrets.yml` is not touched by this plan.** It's vault-encrypted and the
    plaintext vault password (`.vault_pass`) is gitignored and machine-specific — not present in this
    worktree, and rotating a live production secret is a stateful operation that must not run from an
    ephemeral worktree. The plan updates `secrets.yml.example` and the k3s role's Secret-manifest
    template (both templates/examples, safe to edit anywhere) and adds a helper script to generate the
    hash — but the actual vault edit + redeploy is a manual step for the user, done in their main
    checkout with the real vault password. See Non-goals.

## Backend

### New env vars (`ansible-project/roles/backend/files/backend/app.py`)

Replace:
```python
ADMIN_SECRET = os.environ['ADMIN_SECRET']
```
with:
```python
ADMIN_USERNAME = os.environ['ADMIN_USERNAME']
ADMIN_PASSWORD_HASH = os.environ['ADMIN_PASSWORD_HASH']
ADMIN_SESSION_SECRET = os.environ['ADMIN_SESSION_SECRET']
```

### Token serializer

```python
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired
from werkzeug.security import check_password_hash

_admin_token_serializer = URLSafeTimedSerializer(ADMIN_SESSION_SECRET, salt='admin-session')
ADMIN_TOKEN_MAX_AGE = 12 * 60 * 60  # 12 hours, in seconds
```

### `require_admin`, rewritten

```python
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

All 8 existing routes decorated with `@require_admin` (previous/upcoming party CRUD + reassign, votes
list/delete) need no changes — the decorator's external contract (401 on failure, pass-through on
success) is unchanged.

### New route: `POST /api/admin/login`

Unauthenticated (it's how a token is obtained in the first place):

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

Note `check_password_hash` always runs, even when `username_ok` is already `False` — this is
deliberate (Decision 7), not incidental; do not short-circuit with `and` short-circuit evaluation
ordering that skips it.

### Helper script for provisioning

`ansible-project/roles/backend/files/backend/scripts/hash_admin_password.py` — a small operator tool
(not used by the app itself at runtime) that turns a chosen password into the value to paste into
`ADMIN_PASSWORD_HASH`:

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

Run via the backend venv (`werkzeug` is already a dependency there): `cd
ansible-project/roles/backend/files/backend && source .venv/bin/activate && python
scripts/hash_admin_password.py`.

## Frontend

### `admin.html`

The existing secret-only form (from Task 7) is replaced:

```html
<form id="secret-form">
  <label>Username: <input type="text" id="username-input" required autocomplete="username"></label>
  <label>Password: <input type="password" id="password-input" required autocomplete="current-password"></label>
  <button type="submit">Log in</button>
  <p class="error" id="secret-error"></p>
</form>
```

`#secret-gate` and `#secret-error` keep their existing IDs (still valid concepts — a gate, an error
message); `#secret-input` is removed, replaced by `#username-input` + `#password-input`.

A "Log out" button is added inside `#admin-content`, near the tab bar:

```html
<button type="button" id="logout-button">Log out</button>
```

### `admin.js`

The existing secret-storage constant and `adminHeaders()` (from Task 8) change:

```javascript
const ADMIN_TOKEN_KEY = 'voteballAdminToken';

function adminHeaders() {
  return { 'Authorization': 'Bearer ' + (sessionStorage.getItem(ADMIN_TOKEN_KEY) || '') };
}
```

Every other use of the old `ADMIN_SECRET_KEY` constant (in `adminFetch`'s 401 handler, the submit
handler, and `tryEnterWithStoredSecret`) is renamed to `ADMIN_TOKEN_KEY` — same
`sessionStorage.setItem`/`removeItem`/`getItem` call shape, just the stored value is now a token, not
a password.

The secret-form submit handler now POSTs to `/api/admin/login` instead of probing
`/api/admin/votes` directly:

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
```

`tryEnterWithStoredToken()` (renamed from `tryEnterWithStoredSecret`) keeps its existing shape — it
still probes `GET /api/admin/votes` with the stored credential (now `Authorization: Bearer <token>`
via `adminHeaders()`-equivalent construction) to check whether the session is still valid on page
load, exactly as it did for the raw secret. No change to `adminFetch`'s 401-handling logic
(`showGate('Session expired — re-enter the secret.')`) beyond the storage-key rename — a stale/expired
token is indistinguishable from a wrong password at the `require_admin` layer, so the existing
uniform 401 → re-gate flow is unaffected by this redesign.

New logout handler:

```javascript
document.getElementById('logout-button').addEventListener('click', () => {
  sessionStorage.removeItem(ADMIN_TOKEN_KEY);
  showGate();
});
```

No server call — stateless tokens mean there's nothing server-side to invalidate; clearing the client
copy is the entire "log out" operation.

## Deployment

### `ansible-project/inventories/voteball/group_vars/all/secrets.yml.example`

Replace:
```
admin_secret: your_admin_secret_here
```
with:
```
admin_username: your_admin_username_here
admin_password_hash: your_admin_password_hash_here   # generate via: cd ansible-project/roles/backend/files/backend && source .venv/bin/activate && python scripts/hash_admin_password.py
admin_session_secret: your_random_session_secret_here   # generate via: openssl rand -hex 32
```

### `ansible-project/roles/k3s/tasks/main.yml`

In the `app-secret` Secret manifest's `data:` block, replace:
```yaml
ADMIN_SECRET: "{{ admin_secret | b64encode }}"
```
with:
```yaml
ADMIN_USERNAME: "{{ admin_username | b64encode }}"
ADMIN_PASSWORD_HASH: "{{ admin_password_hash | b64encode }}"
ADMIN_SESSION_SECRET: "{{ admin_session_secret | b64encode }}"
```

### The real `secrets.yml` is not touched by this plan

`ansible-project/inventories/voteball/group_vars/all/secrets.yml` is committed, vault-encrypted, and
already contains a real `admin_secret` value. This plan does not edit it — doing so requires the real
`.vault_pass` (gitignored, machine-specific, not present in this worktree) and constitutes a stateful
production-secret rotation, which must happen in the user's main checkout, not from an ephemeral
worktree. **This is a breaking change**: once this branch is merged and deployed, the backend
container will fail to start without `ADMIN_USERNAME`/`ADMIN_PASSWORD_HASH`/`ADMIN_SESSION_SECRET` set
— the user must run `ansible-vault edit inventories/voteball/group_vars/all/secrets.yml
--vault-password-file .vault_pass`, replace `admin_secret` with the three new keys (generating the
password hash via the new helper script and the session secret via `openssl rand -hex 32`), before the
next `ansible-playbook` run. `docs/deploy.md` gets a note about this migration step.

## Testing

### Backend

- New tests for `POST /api/admin/login`: correct credentials → `200` with a `token` field present;
  wrong password → `401 {"error": "invalid username or password"}`; wrong username → same `401`
  (identical body — don't let the two cases be distinguishable); missing username or password in the
  body → same `401` (treated as just another invalid-credentials case, not a separate `400`).
- New tests for `require_admin`'s token verification: valid token → request proceeds; missing
  `Authorization` header → `401`; header present but not `Bearer `-prefixed → `401`; well-formed but
  signature-invalid token (e.g. a token minted with a different secret) → `401`; expired token → `401`
  (construct an already-expired token by mocking the clock at mint time, then verify against the real
  `ADMIN_TOKEN_MAX_AGE` — exact mocking approach is an implementation-plan-level decision, not fixed
  here).
- **Existing tests migrate to a shared fixture** instead of each hardcoding
  `headers = {'X-Admin-Secret': 'test-admin-secret'}` (roughly 20 call sites across `test_app.py`):
  ```python
  @pytest.fixture
  def admin_headers(client):
      resp = client.post('/api/admin/login', json={'username': 'testadmin', 'password': 'test-admin-password'})
      token = resp.get_json()['token']
      return {'Authorization': f'Bearer {token}'}
  ```
  `tests/conftest.py`'s env var defaults change from `ADMIN_SECRET` to `ADMIN_USERNAME=testadmin`,
  `ADMIN_PASSWORD_HASH=<hash of 'test-admin-password'>` (computed once via
  `werkzeug.security.generate_password_hash` at module load), and `ADMIN_SESSION_SECRET` (any fixed
  test string). Every test currently taking a literal `headers` dict is updated to take the
  `admin_headers` fixture parameter instead and use it directly as the `headers=` argument.

### Frontend

No automated suite (per `CLAUDE.md`, unchanged). Manual browser verification, updated from the
admin-ui spec's checklist:

- Wrong username or wrong password shows "Incorrect username or password." and does not reveal tabs.
- Correct credentials reveal the tabs; refreshing the tab within 12 hours skips the login form.
- "Log out" clears the session and re-shows the login form; a subsequent action requires logging in
  again.
- All the existing admin-ui checks (party CRUD, reassign, votes list/delete, session-expired
  re-prompt) still work end-to-end with the new login flow in front of them.

## Non-goals

- No multi-user support — one account, one username, one password.
- No server-side session revocation or logout endpoint — logout is client-side only; a leaked token
  remains valid until its natural 12-hour expiry or until `ADMIN_SESSION_SECRET` is rotated.
- No rate limiting or lockout on failed login attempts.
- No "forgot password" or self-service password reset/change flow (password rotation is the same
  vault-edit-and-redeploy operation as any other secret change).
- No change to the admin permission model itself — authentication is still all-or-nothing (logged in
  = full admin access), matching today's single-shared-secret model; this redesign changes *how* you
  prove you're the admin, not *what* an admin can do.
- Does not touch the real, deployed `secrets.yml` — that rotation is a manual step for the user,
  outside this plan's automated tasks (see Deployment).
- `CLAUDE.md`'s "Admin auth is a static shared secret... not per-user auth" line is updated to
  describe this new model — a deliberate, explicit reversal of a previously-documented constraint, not
  an oversight.
