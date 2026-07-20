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
