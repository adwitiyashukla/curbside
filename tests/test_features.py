import psycopg
import pytest


def month_count(conn, month):
    return conn.execute(
        "select count(*) from core.violations where date_trunc('month', issue_date) = %s",
        (month,),
    ).fetchone()[0]


def test_fine_changes_are_audited(conn):
    with conn.transaction(force_rollback=True):
        conn.execute(
            "update core.violation_codes set fine_elsewhere = fine_elsewhere + 5 where violation_code = 21"
        )
        row = conn.execute(
            "select old_fine_elsewhere, new_fine_elsewhere, changed_by from core.fine_history where violation_code = 21"
        ).fetchone()
        assert row[1] - row[0] == 5
        assert row[2] != ""


def test_unchanged_fines_are_not_audited(conn):
    with conn.transaction(force_rollback=True):
        conn.execute(
            "update core.violation_codes set fine_elsewhere = fine_elsewhere where violation_code = 21"
        )
        assert conn.execute("select count(*) from core.fine_history").fetchone()[0] == 0


def busiest_month(conn):
    return conn.execute(
        "select date_trunc('month', issue_date)::date from core.violations group by 1 order by count(*) desc limit 1"
    ).fetchone()[0]


def mart_count(conn, month):
    return conn.execute(
        "select sum(tickets) from mart.daily_tickets where date_trunc('month', issue_date) = %s",
        (month,),
    ).fetchone()[0]


def reload_as_loader(conn, month):
    conn.execute("set role curbside_loader")
    try:
        conn.execute("call core.reload_month(%s)", (month,))
    finally:
        conn.execute("reset role")


def test_reload_month_picks_up_changes_in_the_stage(conn):
    month = busiest_month(conn)
    before = month_count(conn, month)
    sample = conn.execute(
        """
        select raw_id from etl.stage_violations
        where reject_reason is null and date_trunc('month', issue_date) = %s
        order by raw_id
        limit 1
        """,
        (month,),
    ).fetchone()[0]
    columns = [
        r[0]
        for r in conn.execute(
            """
            select column_name from information_schema.columns
            where table_schema = 'etl' and table_name = 'stage_violations'
            order by ordinal_position
            """
        )
    ]
    changes = {
        "raw_id": "-1",
        "summons_number": "1",
        "plate_id": "'ZZTEST1'",
        "state_code": "null",
        "street_name": "'TEST ST'",
        "issuer_code": "999999",
    }
    conn.execute(
        f"insert into etl.stage_violations ({', '.join(columns)}) "
        f"select {', '.join(changes.get(c, c) for c in columns)} from etl.stage_violations where raw_id = %s",
        (sample,),
    )
    try:
        reload_as_loader(conn, month)
        assert month_count(conn, month) == before + 1
        assert mart_count(conn, month) == before + 1
        added = conn.execute(
            """
            select v.vehicle_id is not null, v.state_code is null, s.street_id is not null, t.issuer_id is not null
            from core.violations t
            left join core.vehicles v on v.vehicle_id = t.vehicle_id
            left join core.streets s on s.street_id = t.street_id and s.street_name = 'TEST ST'
            where t.summons_number = 1
            """
        ).fetchone()
        assert added == (True, True, True, True)
    finally:
        conn.execute("delete from etl.stage_violations where raw_id = -1")
        reload_as_loader(conn, month)
        conn.execute("delete from core.vehicles where plate_id = 'ZZTEST1'")
        conn.execute("delete from core.streets where street_name = 'TEST ST'")
        conn.execute("delete from core.issuers where issuer_code = 999999")
    assert month_count(conn, month) == before
    assert mart_count(conn, month) == before


def test_reload_refuses_an_empty_stage(conn):
    month = busiest_month(conn)
    before = month_count(conn, month)
    with conn.transaction(force_rollback=True):
        conn.execute(
            "update etl.stage_violations set reject_reason = 'test' where date_trunc('month', issue_date) = %s",
            (month,),
        )
        with pytest.raises(psycopg.errors.RaiseException, match="no clean rows"):
            conn.execute("call core.reload_month(%s)", (month,))
    assert month_count(conn, month) == before


def test_reload_refuses_a_month_outside_the_window(conn):
    with pytest.raises(psycopg.errors.RaiseException, match="outside the load window"):
        conn.execute("call core.reload_month('2020-01-01')")


def test_reader_role_cannot_write(conn):
    with conn.transaction(force_rollback=True):
        conn.execute("set local role curbside_reader")
        assert conn.execute("select count(*) from core.violations").fetchone()[0] > 0
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("delete from core.violations")


def test_plate_history_is_in_date_order(conn):
    plate = conn.execute(
        """
        select v.plate_id, v.state_code
        from mart.vehicle_activity a
        join core.vehicles v on v.vehicle_id = a.vehicle_id
        order by a.tickets desc, a.vehicle_id
        limit 1
        """
    ).fetchone()
    dates = [r[0] for r in conn.execute("select issue_date from core.plate_history(%s, %s)", plate)]
    assert len(dates) > 1
    assert dates == sorted(dates)
