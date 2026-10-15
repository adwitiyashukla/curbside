import pytest

from curbside import bench, db, erd

QUERIES = sorted(db.QUERIES_DIR.glob("*.sql"))


@pytest.mark.parametrize("path", QUERIES, ids=[p.stem for p in QUERIES])
def test_query_runs(conn, path):
    cur = conn.execute(path.read_text(encoding="utf-8"))
    assert cur.description is not None
    cur.fetchall()


def test_benchmarks_are_valid(conn, built):
    items = bench.load_benchmarks()
    assert len(items) >= 5
    result = bench.run_one(conn, items[0], built.repeats)
    assert result["slow_ms"] > 0 and result["fast_ms"] > 0


def test_erd_lists_every_core_table(built):
    text = erd.render(built)
    assert text.startswith("erDiagram")
    for table in ("violations", "vehicles", "streets", "boroughs", "violation_codes"):
        assert f"    {table} {{" in text
    assert "vehicles |o--o{ violations" in text
