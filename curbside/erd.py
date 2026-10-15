from curbside import db

SCHEMAS = ["core"]

COLUMNS = """
select c.relname, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid
where n.nspname = any(%s)
  and c.relkind in ('r', 'p')
  and not c.relispartition
  and a.attnum > 0
  and not a.attisdropped
order by c.relname, a.attnum
"""

KEYS = """
select c.contype, src.relname, dst.relname, array_agg(a.attname order by k.ord)
from pg_constraint c
join pg_class src on src.oid = c.conrelid
join pg_namespace n on n.oid = src.relnamespace
left join pg_class dst on dst.oid = c.confrelid
cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
where n.nspname = any(%s)
  and c.contype in ('p', 'f', 'u')
  and not src.relispartition
  and c.conparentid = 0
group by c.oid, c.contype, src.relname, dst.relname
order by src.relname, dst.relname
"""


def short_type(pg_type):
    name = pg_type.split("(")[0]
    return {
        "time without time zone": "time",
        "timestamp with time zone": "timestamptz",
        "character varying": "varchar",
    }.get(name, name).replace(" ", "_")


def render(cfg):
    with db.connect(cfg) as conn:
        columns = conn.execute(COLUMNS, (SCHEMAS,)).fetchall()
        keys = conn.execute(KEYS, (SCHEMAS,)).fetchall()

    primary = {(t, c) for kind, t, _, cols in keys if kind == "p" for c in cols}
    foreign = {(t, c) for kind, t, _, cols in keys if kind == "f" for c in cols}
    unique = {(t, c) for kind, t, _, cols in keys if kind == "u" for c in cols}
    not_null = {(t, c) for t, c, _, nn in columns if nn}

    lines = ["erDiagram"]
    table = None
    for name, column, pg_type, _ in columns:
        if name != table:
            if table is not None:
                lines.append("    }")
            lines.append(f"    {name} {{")
            table = name
        marks = []
        for mark, keyset in (("PK", primary), ("FK", foreign), ("UK", unique)):
            if (name, column) in keyset:
                marks.append(mark)
        suffix = f" {', '.join(marks)}" if marks else ""
        lines.append(f"        {short_type(pg_type)} {column}{suffix}")
    if table is not None:
        lines.append("    }")

    for kind, child, parent, cols in keys:
        if kind != "f":
            continue
        required = all((child, c) in not_null for c in cols)
        left = "||" if required else "|o"
        lines.append(f'    {parent} {left}--o{{ {child} : "{", ".join(cols)}"')
    return "\n".join(lines)
