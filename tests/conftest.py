import dataclasses
from pathlib import Path

import psycopg
import pytest

from curbside import config, db, pipeline

ROOT = Path(__file__).resolve().parent.parent
TEST_DB = "curbside_test"


@pytest.fixture(scope="session")
def cfg():
    base = config.load(ROOT / "config.toml")
    return dataclasses.replace(
        base,
        dbname=TEST_DB,
        data_dir=ROOT / "tests" / "data",
        min_precinct_tickets=5,
        repeats=1,
    )


@pytest.fixture(scope="session")
def built(cfg):
    with psycopg.connect(
        host=cfg.host, port=cfg.port, dbname="postgres", user=cfg.user, autocommit=True
    ) as admin:
        if admin.execute("select 1 from pg_database where datname = %s", (TEST_DB,)).fetchone() is None:
            admin.execute(f"create database {TEST_DB}")
    pipeline.load(cfg)
    pipeline.build(cfg)
    return cfg


@pytest.fixture()
def conn(built):
    with db.connect(built) as c:
        yield c
