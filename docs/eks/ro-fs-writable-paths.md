# readOnlyRootFilesystem: writable-path audit

Input for the EKS Helm chart (a later plan). Under `securityContext.readOnlyRootFilesystem: true`,
a container's root filesystem is read-only, so it can only write to paths backed by a writable
volume (an `emptyDir`). This table records every path each container actually needs to write, so the
chart can mount exactly those and nothing more. Audited 2026-07-19 while implementing the app-code
foundation.

| Container | Writable path needed | Why |
|---|---|---|
| backend  | `/tmp` | gunicorn's default `worker_tmp_dir` is `/tmp` — it writes small master↔worker heartbeat temp files there. Options for the chart: mount an `emptyDir` at `/tmp`, or set `worker_tmp_dir = /dev/shm` in `gunicorn.conf.py` and mount an `emptyDir` (medium: Memory) at `/dev/shm`. |
| worker   | `/tmp` | The heartbeat file `/tmp/heartbeat` (see `heartbeat.py`, `DEFAULT_PATH`). Mount an `emptyDir` at `/tmp`. The liveness probe reads this file's mtime. |
| frontend | (deferred) | Handled by the frontend base-image swap to `nginxinc/nginx-unprivileged` (which relocates the pid/cache writes) in the infra/chart plan — not part of the app-code foundation plan, because stripping in-pod TLS would break the live k3s site. |

## Notes carried into the chart plan

- **Heartbeat path is overridable** via the `HEARTBEAT_FILE` env var, but defaults to `/tmp/heartbeat`;
  keep the chart's `emptyDir` mount, the env var (if set), and the liveness-probe path in agreement.
- **Base image tags stay floating** (`python:3.12-slim`) by decision (2026-07-19) — convenience over
  reproducibility. The `.dockerignore` files already exclude `tests/`, `__pycache__/`, `.pytest_cache/`,
  `.venv/`, so no image-hygiene change was needed in this plan. This trade-off gets narrated in
  `docs/security.md` (submission-artifacts plan).
- **S3 export is env-gated** (`S3_BUCKET`): unset ⇒ the worker makes no S3 calls, which is why these
  app-code changes are inert on the current k3s deployment.
