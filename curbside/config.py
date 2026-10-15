import re
import tomllib
from dataclasses import dataclass
from pathlib import Path

MEMORY = re.compile(r"^[1-9][0-9]*(kB|MB|GB)$")
DATASET = re.compile(r"^[a-z0-9]{4}-[a-z0-9]{4}$")
NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

SECTIONS = {
    "database": {"host": str, "port": int, "dbname": str, "user": str},
    "data": {
        "dir": str,
        "base_url": str,
        "violations_dataset": str,
        "codes_dataset": str,
        "fiscal_year": int,
        "late_months": int,
    },
    "load": {"chunk_kb": int},
    "build": {
        "work_mem": str,
        "maintenance_work_mem": str,
        "effective_cache_size": str,
        "parallel_workers": int,
        "profile_sample_percent": float,
        "make_match_distance": int,
        "make_match_prefix": int,
        "make_match_ratio": int,
        "min_precinct_tickets": int,
        "precinct_majority": float,
    },
    "bench": {"repeats": int},
}


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class Config:
    host: str
    port: int
    dbname: str
    user: str
    data_dir: Path
    base_url: str
    violations_dataset: str
    codes_dataset: str
    fiscal_year: int
    late_months: int
    chunk_kb: int
    work_mem: str
    maintenance_work_mem: str
    effective_cache_size: str
    parallel_workers: int
    profile_sample_percent: float
    make_match_distance: int
    make_match_prefix: int
    make_match_ratio: int
    min_precinct_tickets: int
    precinct_majority: float
    repeats: int

    @property
    def violations_file(self):
        return self.data_dir / f"parking_violations_fy{self.fiscal_year}.csv.gz"

    @property
    def codes_file(self):
        return self.data_dir / "violation_codes.csv"


def check(ok, message):
    if not ok:
        raise ConfigError(message)


def read_values(raw):
    values = {}
    check(isinstance(raw, dict), "config must be a table")
    for section, keys in SECTIONS.items():
        table = raw.get(section)
        check(isinstance(table, dict), f"missing section [{section}]")
        unknown = sorted(set(table) - set(keys))
        check(not unknown, f"unknown keys in [{section}]: {', '.join(unknown)}")
        for key, kind in keys.items():
            check(key in table, f"missing [{section}] {key}")
            value = table[key]
            if kind is float and type(value) is int:
                value = float(value)
            check(type(value) is kind, f"[{section}] {key} must be {kind.__name__}")
            values[key] = value
    extra = sorted(set(raw) - set(SECTIONS))
    check(not extra, f"unknown sections: {', '.join(extra)}")
    return values


def validate(v):
    check(v["host"].strip() != "", "[database] host is empty")
    check(1 <= v["port"] <= 65535, "[database] port must be between 1 and 65535")
    check(NAME.match(v["dbname"]) is not None, "[database] dbname is not a plain name")
    check(NAME.match(v["user"]) is not None, "[database] user is not a plain name")
    check(v["base_url"].startswith("https://"), "[data] base_url must start with https://")
    check(DATASET.match(v["violations_dataset"]) is not None, "[data] violations_dataset looks wrong")
    check(DATASET.match(v["codes_dataset"]) is not None, "[data] codes_dataset looks wrong")
    check(2014 <= v["fiscal_year"] <= 2100, "[data] fiscal_year must be between 2014 and 2100")
    check(0 <= v["late_months"] <= 6, "[data] late_months must be between 0 and 6")
    check(64 <= v["chunk_kb"] <= 65536, "[load] chunk_kb must be between 64 and 65536")
    check(MEMORY.match(v["work_mem"]) is not None, "[build] work_mem must look like 256MB")
    check(
        MEMORY.match(v["maintenance_work_mem"]) is not None,
        "[build] maintenance_work_mem must look like 512MB",
    )
    check(
        MEMORY.match(v["effective_cache_size"]) is not None,
        "[build] effective_cache_size must look like 1GB",
    )
    check(0 <= v["parallel_workers"] <= 16, "[build] parallel_workers must be between 0 and 16")
    check(
        0 < v["profile_sample_percent"] <= 100,
        "[build] profile_sample_percent must be above 0 and at most 100",
    )
    check(0 <= v["make_match_distance"] <= 2, "[build] make_match_distance must be 0, 1 or 2")
    check(0 <= v["make_match_prefix"] <= 5, "[build] make_match_prefix must be between 0 and 5")
    check(2 <= v["make_match_ratio"] <= 10000, "[build] make_match_ratio must be between 2 and 10000")
    check(v["min_precinct_tickets"] >= 1, "[build] min_precinct_tickets must be at least 1")
    check(
        0.5 < v["precinct_majority"] <= 1,
        "[build] precinct_majority must be above 0.5 and at most 1",
    )
    check(1 <= v["repeats"] <= 50, "[bench] repeats must be between 1 and 50")


def parse(raw, base_dir):
    values = read_values(raw)
    validate(values)
    data_dir = Path(values.pop("dir"))
    if not data_dir.is_absolute():
        data_dir = base_dir / data_dir
    return Config(data_dir=data_dir, **values)


def load(path):
    path = Path(path)
    check(path.exists(), f"config file not found: {path}")
    with path.open("rb") as f:
        try:
            raw = tomllib.load(f)
        except tomllib.TOMLDecodeError as e:
            raise ConfigError(f"{path}: {e}") from None
    return parse(raw, path.resolve().parent)
