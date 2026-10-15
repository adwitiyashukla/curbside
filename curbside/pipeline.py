import csv
import gzip
import re
import time
import urllib.request

from curbside import db

USER_AGENT = "curbside/0.1"
BUILD_FILES = [
    "02_etl.sql",
    "seeds",
    "03_profile.sql",
    "04_reference.sql",
    "05_stage.sql",
    "06_core.sql",
    "07_violations.sql",
    "08_indexes.sql",
    "09_quality.sql",
    "10_marts.sql",
    "11_features.sql",
]


def export_url(cfg, dataset):
    return f"{cfg.base_url}/{dataset}/export.csv?accessType=DOWNLOAD"


def fetch(url, target, gzipped):
    part = target.with_name(target.name + ".part")
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip" if gzipped else "identity"}
    )
    started = time.perf_counter()
    written = 0
    next_report = 25 * 1024 * 1024
    with urllib.request.urlopen(request, timeout=120) as resp, part.open("wb") as out:
        encoded = resp.headers.get("Content-Encoding", "").lower() == "gzip"
        sink = out if (encoded or not gzipped) else gzip.GzipFile(fileobj=out, mode="wb")
        source = gzip.GzipFile(fileobj=resp) if (encoded and not gzipped) else resp
        while chunk := source.read(1024 * 1024):
            sink.write(chunk)
            written += len(chunk)
            if written >= next_report:
                minutes = (time.perf_counter() - started) / 60
                print(f"  {written / 1e6:,.0f} MB in {minutes:.1f} min", flush=True)
                next_report += 25 * 1024 * 1024
        if sink is not out:
            sink.close()
    part.replace(target)
    return written


def download(cfg, force=False):
    cfg.data_dir.mkdir(parents=True, exist_ok=True)
    jobs = [
        (cfg.codes_dataset, cfg.codes_file, False),
        (cfg.violations_dataset, cfg.violations_file, True),
    ]
    for dataset, target, gzipped in jobs:
        if target.exists() and not force:
            print(f"{target.name} already there, skipping")
            continue
        print(f"downloading {target.name}")
        size = fetch(export_url(cfg, dataset), target, gzipped)
        print(f"  saved {size / 1e6:,.1f} MB")


def column_name(header):
    return re.sub(r"[^a-z0-9]+", "_", header.strip().lower()).strip("_")


def header_columns(first_line, expected):
    names = [column_name(h) for h in next(csv.reader([first_line]))]
    missing = sorted(set(expected) - set(names))
    unknown = sorted(set(names) - set(expected))
    if missing or unknown or len(names) != len(set(names)):
        raise ValueError(f"unexpected csv header, missing={missing} unknown={unknown}")
    return names


def load_file(conn, cfg, path, table, opener):
    schema, name = table.split(".")
    expected = db.table_columns(conn, schema, name)
    with opener(path) as f:
        columns = header_columns(f.readline().decode("utf-8-sig"), expected)
    started = time.perf_counter()
    with conn.transaction():
        conn.execute(f"truncate table {table} restart identity")
        with opener(path) as f:
            rows = db.copy_stream(conn, table, columns, f, cfg.chunk_kb * 1024, freeze=True)
        seconds = time.perf_counter() - started
        conn.execute(
            "insert into raw.loads (file_name, table_name, row_count, seconds) values (%s, %s, %s, %s)",
            (path.name, table, rows, round(seconds, 2)),
        )
    print(f"  {table}: {rows:,} rows in {seconds:.1f}s ({rows / max(seconds, 0.001):,.0f} rows/s)")
    return rows


def load(cfg, conn=None):
    for path in (cfg.codes_file, cfg.violations_file):
        if not path.exists():
            raise FileNotFoundError(f"{path} is missing, run the download step first")
    own = conn is None
    conn = conn or db.connect(cfg)
    try:
        db.run_file(conn, db.SQL_DIR / "01_raw.sql")
        load_file(conn, cfg, cfg.codes_file, "raw.violation_codes", lambda p: p.open("rb"))
        load_file(conn, cfg, cfg.violations_file, "raw.parking_violations", gzip.open)
        conn.execute("analyze raw.parking_violations")
    finally:
        if own:
            conn.close()


def load_seeds(conn):
    for path in sorted(db.SEEDS_DIR.glob("*.csv")):
        with path.open(encoding="utf-8", newline="") as f:
            header = next(csv.reader(f))
        table = f"etl.seed_{path.stem}"
        columns = ", ".join(f"{column_name(h)} text" for h in header)
        conn.execute(f"create table {table} ({columns})")
        with path.open("rb") as f:
            db.copy_stream(conn, table, [column_name(h) for h in header], f, 1024 * 1024)


def build(cfg, conn=None, start=None):
    steps = BUILD_FILES[BUILD_FILES.index(start):] if start else BUILD_FILES
    own = conn is None
    conn = conn or db.connect(cfg)
    total = time.perf_counter()
    try:
        for step in steps:
            print(f"{step}", flush=True)
            if step == "seeds":
                with conn.transaction():
                    load_seeds(conn)
                continue
            seconds = db.run_file(conn, db.SQL_DIR / step)
            print(f"  done in {seconds:.1f}s", flush=True)
        started = time.perf_counter()
        conn.execute("vacuum core.violations, core.vehicles, mart.daily_tickets, mart.vehicle_activity")
        print(f"vacuum\n  done in {time.perf_counter() - started:.1f}s", flush=True)
        summary(conn)
    finally:
        if own:
            conn.close()
    print(f"build finished in {(time.perf_counter() - total) / 60:.1f} min")


def summary(conn):
    rows = conn.execute(
        "select check_name, expected, actual, passed from quality.checks order by check_id"
    ).fetchall()
    width = max(len(r[0]) for r in rows)
    print("checks")
    for name, expected, actual, passed in rows:
        status = "ok" if passed else "FAILED"
        print(f"  {name:<{width}}  expected {expected:>14,}  actual {actual:>14,}  {status}")
    failed = [r[0] for r in rows if not r[3]]
    if failed:
        raise RuntimeError(f"quality checks failed: {', '.join(failed)}")
