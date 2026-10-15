create table quality.rejects (
    raw_id bigint primary key,
    reason text not null
);

insert into quality.rejects (raw_id, reason)
select raw_id, reject_reason
from etl.stage_violations
where reject_reason is not null;

create view quality.reject_summary as
select
    reason,
    count(*) as rows,
    round(100.0 * count(*) / (select count(*) from raw.parking_violations), 4) as pct_of_raw
from quality.rejects
group by reason
order by rows desc;

create view quality.mapping_coverage as
select 'vehicle make' as field, method, count(*) as spellings, sum(rows) as rows
from etl.make_map
group by method
union all
select 'vehicle color', method, count(*), sum(rows)
from etl.color_map
group by method
union all
select 'body type', method, count(*), sum(rows)
from etl.body_map
group by method;

create view quality.unmatched_values as
select 'violation precinct' as field, count(*) as rows
from etl.stage_violations s
where s.reject_reason is null
  and s.precinct is not null
  and not exists (select 1 from core.precincts p where p.precinct_id = s.precinct)
union all
select 'registration state', coalesce(sum(rows), 0)
from etl.raw_values
where field = 'state' and value is not null
  and value not in (select state_code from core.registration_states)
union all
select 'plate type', coalesce(sum(rows), 0)
from etl.raw_values
where field = 'plate_type' and value is not null
  and value not in (select plate_type_code from core.plate_types)
union all
select 'county', coalesce(sum(rows), 0)
from etl.raw_values
where field = 'county' and value is not null
  and value not in (select county_code from etl.county_map);

create table quality.column_nulls (
    column_name text primary key,
    ordinal smallint not null,
    null_rows bigint not null,
    null_pct numeric(6, 2) not null
);

do $$
declare
    cols text[];
    total bigint;
    nulls bigint[];
begin
    select array_agg(attname::text order by attnum)
    into cols
    from pg_attribute
    where attrelid = 'core.violations'::regclass and attnum > 0 and not attisdropped;

    execute format(
        'select count(*), array[%s] from core.violations',
        (select string_agg(format('count(*) filter (where %I is null)', c), ', ') from unnest(cols) c))
    into total, nulls;

    insert into quality.column_nulls (column_name, ordinal, null_rows, null_pct)
    select c, i, nulls[i], round(100.0 * nulls[i] / greatest(total, 1), 2)
    from unnest(cols) with ordinality as u(c, i);
end
$$;

create table quality.checks (
    check_id smallint primary key,
    check_name text not null,
    expected bigint not null,
    actual bigint not null,
    passed boolean generated always as (expected = actual) stored
);

insert into quality.checks (check_id, check_name, expected, actual)
with last_load as (
    select coalesce(
        (select row_count from raw.loads
         where table_name = 'raw.parking_violations'
         order by load_id desc
         limit 1), -1) as row_count
)
select check_id, check_name, expected, actual
from last_load, lateral (
    values
    (1, 'raw rows match the last load',
        last_load.row_count,
        (select count(*) from raw.parking_violations)),
    (2, 'loaded rows = clean rows + rejects',
        last_load.row_count,
        (select count(*) from core.violations) + (select count(*) from quality.rejects)),
    (3, 'duplicate summons numbers in core',
        0,
        (select count(*) from (
            select summons_number from core.violations group by summons_number having count(*) > 1) d)),
    (4, 'tickets outside the load window',
        0,
        (select count(*) from core.violations
         where issue_date < etl.window_start() or issue_date >= etl.fy_end())),
    (5, 'clean stage rows missing from core',
        0,
        (select count(*) from etl.stage_violations s
         where s.reject_reason is null
           and not exists (
               select 1 from core.violations v
               where v.summons_number = s.summons_number and v.issue_date = s.issue_date))),
    (6, 'tickets with a plate but no vehicle',
        0,
        (select count(*) from etl.stage_violations s
         where s.reject_reason is null and s.plate_id is not null
           and not exists (
               select 1 from core.vehicles v
               where v.plate_id = s.plate_id and v.state_code is not distinct from s.state_code))),
    (7, 'vehicles without any ticket',
        0,
        (select count(*) from core.vehicles v
         where not exists (select 1 from core.violations t where t.vehicle_id = v.vehicle_id))),
    (8, 'streets without any ticket',
        0,
        (select count(*) from core.streets s
         where not exists (select 1 from core.violations t where t.street_id = s.street_id)
           and not exists (select 1 from core.violations t where t.cross_street_id = s.street_id)))
) as c (check_id, check_name, expected, actual);
