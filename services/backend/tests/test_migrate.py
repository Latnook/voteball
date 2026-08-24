import migrate


def test_migrate_main_bootstraps_seed_data(conn):
    # The `conn` fixture already dropped + recreated the schema via init_db, which proves the
    # from-scratch path works. Here we prove migrate.main() -- which opens its OWN connection, the
    # way the EKS migration Job will -- runs cleanly and leaves the seeded reference data in place.
    migrate.main()

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM leagues')
    assert cur.fetchone()[0] > 0
    cur.close()


def test_migrate_main_is_idempotent(conn):
    # Running the migration twice back-to-back must not raise. This is the property that makes it
    # safe to run on every release (and is why schema.sql uses CREATE TABLE IF NOT EXISTS and
    # seed.sql uses ON CONFLICT DO NOTHING).
    migrate.main()
    migrate.main()

    cur = conn.cursor()
    cur.execute('SELECT COUNT(*) FROM previous_parties')
    assert cur.fetchone()[0] > 0
    cur.close()


def test_migrate_succeeds_without_grafana_password(conn, monkeypatch, capsys):
    """A missing monitoring credential must never block a release.

    migrate.py runs as a pre-upgrade Helm hook. Raising here would stop the application deploying
    because a dashboard cannot log in -- so an absent GRAFANA_DB_PASSWORD prints a notice and
    succeeds. This is what lets the GitHub/Postgres data sources be wired last, after the rest of
    the change is already live.
    """
    monkeypatch.delenv('GRAFANA_DB_PASSWORD', raising=False)
    migrate._set_grafana_password(conn)
    assert 'not set' in capsys.readouterr().out


def test_migrate_sets_grafana_password_when_present(conn, monkeypatch, capsys):
    monkeypatch.setenv('GRAFANA_DB_PASSWORD', 'test-password-not-a-real-secret')
    migrate._set_grafana_password(conn)
    assert 'password set' in capsys.readouterr().out
    cur = conn.cursor()
    cur.execute("SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'grafana_ro'")
    assert cur.fetchone()[0] is True
    cur.close()


def test_migrate_password_set_but_role_absent_does_not_raise(conn, monkeypatch, capsys):
    """The scenario a permission-lacking fork can hit for real: GRAFANA_DB_PASSWORD IS set, but
    grafana_ro was never created -- schema.sql's own CREATE ROLE degrades to a NOTICE instead of
    raising when the connecting user lacks CREATEROLE (see the DO block there). An unguarded
    `ALTER ROLE grafana_ro WITH PASSWORD ...` on a role that doesn't exist raises UndefinedObject,
    which would crash this Job -- a pre-upgrade Helm hook -- and block the release. Reproduces the
    absent-role state for real (drop it, don't just imagine it) rather than mocking anything.
    """
    cur = conn.cursor()
    cur.execute('DROP OWNED BY grafana_ro CASCADE')
    cur.execute('DROP ROLE grafana_ro')
    conn.commit()
    cur.close()

    monkeypatch.setenv('GRAFANA_DB_PASSWORD', 'test-password-not-a-real-secret')
    migrate._set_grafana_password(conn)  # must NOT raise

    out = capsys.readouterr().out
    assert 'does not exist' in out, 'notice must name the reason, not just skip silently'
