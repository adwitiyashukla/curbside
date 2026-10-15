create table quality.column_profile (
    column_name text primary key,
    ordinal smallint not null,
    total_rows bigint not null,
    blank_rows bigint not null,
    zero_rows bigint not null,
    sample_distinct bigint not null,
    sample_top_value text,
    sample_top_share numeric(5, 4)
);

do $$
declare
    cols text[];
    total bigint;
    blanks bigint[];
    zeros bigint[];
    pct numeric := etl.setting('profile_sample_percent')::numeric;
    i integer;
    n_distinct bigint;
    top_value text;
    top_share numeric;
begin
    select array_agg(column_name::text order by ordinal_position)
    into cols
    from information_schema.columns
    where table_schema = 'raw' and table_name = 'parking_violations' and column_name <> 'raw_id';

    execute format(
        'select count(*), array[%s], array[%s] from raw.parking_violations',
        (select string_agg(format('count(*) filter (where nullif(trim(%I), '''') is null)', c), ', ')
         from unnest(cols) c),
        (select string_agg(format('count(*) filter (where trim(%I) = ''0'')', c), ', ')
         from unnest(cols) c))
    into total, blanks, zeros;

    for i in 1 .. array_length(cols, 1) loop
        execute format(
            'select count(v), (array_agg(v order by n desc, v) filter (where v is not null))[1],
                    max(n) filter (where v is not null)::numeric / nullif(sum(n), 0)
             from (select nullif(trim(%I), '''') as v, count(*) as n
                   from raw.parking_violations tablesample system (%s) repeatable (7)
                   group by 1) s',
            cols[i], pct)
        into n_distinct, top_value, top_share;

        insert into quality.column_profile
        values (cols[i], i, total, blanks[i], zeros[i], n_distinct, top_value, round(top_share, 4));
    end loop;

    raise notice 'profiled % columns over % rows', array_length(cols, 1), total;
end
$$;
