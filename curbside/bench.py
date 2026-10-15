import json
import statistics
import tomllib

import psycopg

from curbside import db

BENCHMARKS = db.ROOT / "benchmarks.toml"

INDEX_SETTINGS = ["enable_indexscan", "enable_bitmapscan", "enable_indexonlyscan"]

SLOW_SETTINGS = {
    "index": INDEX_SETTINGS,
    "pruning": INDEX_SETTINGS + ["enable_partition_pruning"],
}

FAST_SETTINGS = {
    "index": [],
    "pruning": INDEX_SETTINGS,
}

LABELS = {
    "index": ("no index", "index"),
    "pruning": ("all partitions", "pruned"),
    "pair": ("first query", "second query"),
}


def load_benchmarks(path=BENCHMARKS):
    with open(path, "rb") as f:
        items = tomllib.load(f)["bench"]
    for item in items:
        if item["mode"] not in LABELS:
            raise ValueError(f"unknown mode {item['mode']!r} in {item['name']!r}")
        if item["mode"] == "pair" and "sql_b" not in item:
            raise ValueError(f"{item['name']!r} needs sql_b")
    return items


def pick_params(conn, item):
    if "pick" not in item:
        return {}
    cur = conn.execute(item["pick"])
    row = cur.fetchone()
    if row is None:
        raise RuntimeError(f"pick query for {item['name']!r} returned nothing")
    return dict(zip([c.name for c in cur.description], row))


def scan_types(plan):
    found = set()
    stack = [plan]
    while stack:
        node = stack.pop()
        if node["Node Type"].endswith("Scan") and "Relation Name" in node:
            found.add(node["Node Type"].lower())
        stack.extend(node.get("Plans", []))
    return ", ".join(sorted(found))


def explain(conn, query, params, slow_settings):
    with conn.transaction():
        for name in slow_settings:
            conn.execute(f"set local {name} = off")
        cur = psycopg.ClientCursor(conn)
        cur.execute("explain (analyze, buffers, format json) " + query, params)
        plan = cur.fetchone()[0][0]
    return plan["Execution Time"], scan_types(plan["Plan"])


def measure(conn, query, params, slow_settings, repeats):
    explain(conn, query, params, slow_settings)
    runs = [explain(conn, query, params, slow_settings) for _ in range(repeats)]
    return statistics.median(r[0] for r in runs), runs[-1][1]


def run_one(conn, item, repeats):
    params = pick_params(conn, item)
    if item["mode"] == "pair":
        slow = measure(conn, item["sql"], params, [], repeats)
        fast = measure(conn, item["sql_b"], params, [], repeats)
    else:
        slow = measure(conn, item["sql"], params, SLOW_SETTINGS[item["mode"]], repeats)
        fast = measure(conn, item["sql"], params, FAST_SETTINGS[item["mode"]], repeats)
    return {
        "name": item["name"],
        "mode": item["mode"],
        "slow_label": LABELS[item["mode"]][0],
        "fast_label": LABELS[item["mode"]][1],
        "slow_ms": round(slow[0], 2),
        "fast_ms": round(fast[0], 2),
        "slow_plan": slow[1],
        "fast_plan": fast[1],
        "speedup": round(slow[0] / max(fast[0], 0.001), 1),
    }


def run(cfg):
    items = load_benchmarks()
    results = []
    with db.connect(cfg) as conn:
        for item in items:
            result = run_one(conn, item, cfg.repeats)
            results.append(result)
            print(
                f"{result['name']:<32} {result['slow_label']:>14} {result['slow_ms']:>10.1f} ms"
                f"   {result['fast_label']:>12} {result['fast_ms']:>9.2f} ms   {result['speedup']:>8.1f}x",
                flush=True,
            )
    cfg.data_dir.mkdir(parents=True, exist_ok=True)
    out = cfg.data_dir / "bench.json"
    out.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(f"saved {out}")
    return results
