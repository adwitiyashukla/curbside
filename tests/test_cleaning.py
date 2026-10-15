from datetime import date, time

import pytest


@pytest.mark.parametrize(
    "expression, expected",
    [
        ("etl.to_bigint('4,966,660,087')", 4966660087),
        ("etl.to_bigint('12a')", None),
        ("etl.to_bigint('')", None),
        ("etl.to_int('1,180')", 1180),
        ("etl.parse_mdy('09/29/2025 12:00:00 AM')", date(2025, 9, 29)),
        ("etl.parse_mdy('02/30/2026 12:00:00 AM')", None),
        ("etl.parse_mdy('02/29/2024')", date(2024, 2, 29)),
        ("etl.parse_mdy('1//01/2026')", None),
        ("etl.parse_ymd('20,260,930')", date(2026, 9, 30)),
        ("etl.parse_ymd('88,888,888')", None),
        ("etl.parse_ymd('20,258,888')", None),
        ("etl.parse_ymd('0')", None),
        ("etl.parse_hhmm('0225P')", time(14, 25)),
        ("etl.parse_hhmm('1205A')", time(0, 5)),
        ("etl.parse_hhmm('1205P')", time(12, 5)),
        ("etl.parse_hhmm('0012A')", time(0, 12)),
        ("etl.parse_hhmm('1360P')", None),
        ("etl.parse_hhmm('2330P')", None),
        ("etl.parse_hhmm('0948')", None),
        ("etl.clean_plate(' abc-123 ')", "ABC123"),
        ("etl.clean_plate('BLANKPLATE')", None),
        ("etl.clean_plate('ABC$123')", None),
        ("etl.clean_make('BMW (')", "BMW"),
        ("etl.normalize_street('West 128 Street')", "W 128 ST"),
        ("etl.normalize_street('E 89th STREET')", "E 89 ST"),
        ("etl.normalize_street('Ocean   Avenue')", "OCEAN AVE"),
        ("etl.normalize_street('B''WAY')", "BROADWAY"),
        ("etl.normalize_street('Francis Lewis Blv')", "FRANCIS LEWIS BLVD"),
    ],
)
def test_cleaning_functions(conn, expression, expected):
    assert conn.execute(f"select {expression}").fetchone()[0] == expected


@pytest.mark.parametrize(
    "part1, part2, location, rule",
    [
        ("SB CYPRESS HILLS ST", "@ JAMAICA AVE", "SB CYPRESS HILLS ST @ JAMAICA AVE", "first half was short"),
        ("NB Classon Ave @ Par", "k Ave", "NB Classon Ave @ Park Ave", "lowercase across the cut"),
        ("EB Hillside Ave @ 16", "9th St", "EB Hillside Ave @ 169th St", "digits across the cut"),
        ("EB DITMARS BLVD @ 80", "TH ST", "EB DITMARS BLVD @ 80TH ST", "ordinal after the cut"),
        ("NB 3rd Ave @ E 117th", "St", "NB 3rd Ave @ E 117th St", "new capital after the cut"),
    ],
)
def test_camera_locations_are_rebuilt(conn, part1, part2, location, rule):
    row = conn.execute(
        "select location, join_rule from etl.camera_locations where part1 = %s and part2 = %s",
        (part1, part2),
    ).fetchone()
    assert row == (location, rule)
