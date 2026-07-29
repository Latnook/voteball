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


Same real-Postgres TDD pattern as the backend; reuse the `voteball-test-db` container. The worker's
tests need `schema.sql` (owned by the backend) loaded into that database, since the worker itself
never creates schema.

