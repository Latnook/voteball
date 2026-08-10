# services/worker — CLAUDE.md

Guidance for `services/worker/`. The root `CLAUDE.md` carries the project-wide rules.

**This directory is its own Docker build context and has its own near-duplicate `db.py` rather than
importing the backend's. That is a deliberate simplicity choice, not an oversight — don't "fix" it by
introducing a shared module unless the plan says to.**

**Adding a new source file: update this service's `Dockerfile` `COPY` line.** The build context *is*
this directory, so the Dockerfile's explicit `COPY` list is the only place that can drop a file — and
a missing file is simply absent from the image, with no build error, surfacing as an `ImportError` at
runtime.

## Tests


Same real-Postgres TDD pattern as the backend; reuse the `voteball-test-db` container. **Unlike the
backend, the worker's `tests/conftest.py` does NOT load `schema.sql`.** It defines its own inline
`CREATE TABLE` schema (roughly lines 16-52), a hand-maintained duplicate of the real one. The
backend's `tests/conftest.py` is the one that calls `db.init_db`, which really does load
`schema.sql` + `seed.sql`.

The consequence: adding a column to `schema.sql` does not reach the worker's tests until that inline
duplicate is patched too — a schema change that only touches `services/backend/schema.sql` will make
worker tests either fail on `UndefinedColumn` or, worse, silently pass against a stale schema. Check
`tests/conftest.py`'s inline `CREATE TABLE` list whenever a rollup table's columns change.

