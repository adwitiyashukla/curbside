import tomllib
from pathlib import Path

import pytest

from curbside import config

ROOT = Path(__file__).resolve().parent.parent


def raw_config():
    with open(ROOT / "config.toml", "rb") as f:
        return tomllib.load(f)


def test_repo_config_loads():
    cfg = config.load(ROOT / "config.toml")
    assert cfg.fiscal_year == 2026
    assert cfg.data_dir == ROOT / "data"
    assert cfg.violations_file.name == "parking_violations_fy2026.csv.gz"


@pytest.mark.parametrize(
    "section, key, value, message",
    [
        ("database", "port", 0, "port"),
        ("database", "dbname", "drop table", "dbname"),
        ("data", "fiscal_year", 1999, "fiscal_year"),
        ("data", "late_months", 7, "late_months"),
        ("data", "violations_dataset", "nope", "violations_dataset"),
        ("data", "base_url", "http://example.com", "base_url"),
        ("load", "chunk_kb", 1, "chunk_kb"),
        ("build", "work_mem", "lots", "work_mem"),
        ("build", "effective_cache_size", "4 gigs", "effective_cache_size"),
        ("build", "parallel_workers", True, "parallel_workers"),
        ("build", "precinct_majority", 0.4, "precinct_majority"),
        ("build", "make_match_ratio", 1, "make_match_ratio"),
        ("bench", "repeats", "5", "repeats"),
    ],
)
def test_bad_values_are_rejected(section, key, value, message):
    raw = raw_config()
    raw[section][key] = value
    with pytest.raises(config.ConfigError, match=message):
        config.parse(raw, ROOT)


def test_unknown_key_is_rejected():
    raw = raw_config()
    raw["build"]["work_mme"] = "64MB"
    with pytest.raises(config.ConfigError, match="unknown keys"):
        config.parse(raw, ROOT)


def test_missing_key_is_rejected():
    raw = raw_config()
    del raw["load"]["chunk_kb"]
    with pytest.raises(config.ConfigError, match="missing"):
        config.parse(raw, ROOT)


def test_integer_is_accepted_for_float():
    raw = raw_config()
    raw["build"]["profile_sample_percent"] = 5
    assert config.parse(raw, ROOT).profile_sample_percent == 5.0
