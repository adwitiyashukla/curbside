from curbside import pipeline


def counts(conn):
    return conn.execute(
        """
        select (select count(*) from core.violations),
               (select count(*) from quality.rejects),
               (select count(*) from core.vehicles),
               (select count(*) from core.streets)
        """
    ).fetchone()


def test_all_checks_pass(conn):
    rows = conn.execute("select check_name, passed from quality.checks order by check_id").fetchall()
    assert len(rows) == 8
    assert [name for name, passed in rows if not passed] == []


def test_every_raw_row_is_accounted_for(conn):
    raw = conn.execute("select count(*) from raw.parking_violations").fetchone()[0]
    clean, rejected, _, _ = counts(conn)
    assert raw == clean + rejected
    assert clean > 0 and rejected > 0


def test_expected_reject_reasons(conn):
    reasons = {r[0] for r in conn.execute("select distinct reason from quality.rejects")}
    assert reasons == {
        "bad summons number",
        "bad issue date",
        "duplicate summons number",
        "issue date before load window",
        "issue date after fiscal year",
        "unknown violation code",
        "unknown issuing agency",
    }


def test_late_tickets_are_kept(conn):
    query = "select count(*) from core.violations where issue_date < etl.fy_start()"
    assert conn.execute(query).fetchone()[0] > 0


def test_blank_plates_have_no_vehicle(conn):
    blank = conn.execute(
        """
        select count(*), count(v.vehicle_id)
        from raw.parking_violations r
        join core.violations v on v.summons_number = etl.to_bigint(r.summons_number)
        where upper(trim(r.plate_id)) in ('BLANKPLATE', 'BLANK')
        """
    ).fetchone()
    assert blank[0] > 0 and blank[1] == 0


def test_vehicle_make_is_the_most_common_one(conn):
    seen = conn.execute(
        """
        select make_id, count(*)
        from etl.stage_violations
        where plate_id = 'GGD3953' and state_code = 'NY' and reject_reason is null and make_id is not null
        group by make_id
        order by count(*) desc, make_id
        """
    ).fetchall()
    assert len(seen) == 2 and seen[0][1] > seen[1][1]
    chosen = conn.execute(
        "select make_id from core.vehicles where plate_id = 'GGD3953' and state_code = 'NY'"
    ).fetchone()[0]
    assert chosen == seen[0][0]


def test_rebuild_gives_the_same_result(built, conn):
    before = counts(conn)
    pipeline.build(built)
    assert counts(conn) == before


def test_build_can_resume_from_a_step(cfg, monkeypatch):
    ran = []

    def run_file(conn, path):
        ran.append(path.name)
        return 0.0

    class Conn:
        def execute(self, query):
            ran.append(query.split()[0])

    monkeypatch.setattr(pipeline.db, "run_file", run_file)
    monkeypatch.setattr(pipeline, "summary", lambda conn: None)
    pipeline.build(cfg, conn=Conn(), start="10_marts.sql")
    assert ran == ["10_marts.sql", "11_features.sql", "vacuum"]
