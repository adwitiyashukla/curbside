import select
import time
from pathlib import Path

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parent.parent
SQL_DIR = ROOT / "sql"
SEEDS_DIR = ROOT / "seeds"
QUERIES_DIR = ROOT / "queries"


def print_notice(diag):
    print(f"    {diag.message_primary}", flush=True)


def connect(cfg):
    conn = psycopg.connect(
        host=cfg.host,
        port=cfg.port,
        dbname=cfg.dbname,
        user=cfg.user,
        autocommit=True,
        application_name="curbside",
    )
    conn.add_notice_handler(print_notice)
    settings = {
        "work_mem": cfg.work_mem,
        "maintenance_work_mem": cfg.maintenance_work_mem,
        "effective_cache_size": cfg.effective_cache_size,
        "max_parallel_workers_per_gather": str(cfg.parallel_workers),
        "curbside.fiscal_year": str(cfg.fiscal_year),
        "curbside.late_months": str(cfg.late_months),
        "curbside.profile_sample_percent": str(cfg.profile_sample_percent),
        "curbside.make_match_distance": str(cfg.make_match_distance),
        "curbside.make_match_prefix": str(cfg.make_match_prefix),
        "curbside.make_match_ratio": str(cfg.make_match_ratio),
        "curbside.min_precinct_tickets": str(cfg.min_precinct_tickets),
        "curbside.precinct_majority": str(cfg.precinct_majority),
    }
    for name, value in settings.items():
        conn.execute("select set_config(%s, %s, false)", (name, value))
    return conn


def run_file(conn, path):
    started = time.perf_counter()
    with conn.transaction():
        conn.execute(Path(path).read_text(encoding="utf-8"))
    return time.perf_counter() - started


def drain(pgconn):
    while pgconn.flush() == 1:
        readable, _, _ = select.select([pgconn.socket], [pgconn.socket], [])
        if readable:
            pgconn.consume_input()


def copy_stream(conn, table, columns, stream, chunk_size, freeze=False):
    options = sql.SQL("format csv, header true, freeze true" if freeze else "format csv, header true")
    statement = sql.SQL("copy {} ({}) from stdin with ({})").format(
        sql.Identifier(*table.split(".")),
        sql.SQL(", ").join(sql.Identifier(c) for c in columns),
        options,
    )
    with conn.cursor() as cur:
        with cur.copy(statement) as copy:
            while chunk := stream.read(chunk_size):
                copy.write(chunk)
                drain(conn.pgconn)
        return cur.rowcount


def table_columns(conn, schema, table):
    rows = conn.execute(
        """
        select column_name
        from information_schema.columns
        where table_schema = %s and table_name = %s and is_generated = 'NEVER'
          and identity_generation is null
        order by ordinal_position
        """,
        (schema, table),
    ).fetchall()
    return [r[0] for r in rows]


def scalar(conn, query, params=None):
    return conn.execute(query, params).fetchone()[0]
