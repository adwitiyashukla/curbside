create table core.fine_history (
    change_id bigint generated always as identity primary key,
    violation_code smallint not null references core.violation_codes,
    old_fine_manhattan_south numeric(7, 2) not null,
    new_fine_manhattan_south numeric(7, 2) not null,
    old_fine_elsewhere numeric(7, 2) not null,
    new_fine_elsewhere numeric(7, 2) not null,
    changed_by text not null default current_user,
    changed_at timestamptz not null default now()
);

create function core.log_fine_change() returns trigger
language plpgsql
as $$
begin
    insert into core.fine_history (
        violation_code,
        old_fine_manhattan_south, new_fine_manhattan_south,
        old_fine_elsewhere, new_fine_elsewhere)
    values (
        old.violation_code,
        old.fine_manhattan_south, new.fine_manhattan_south,
        old.fine_elsewhere, new.fine_elsewhere);
    return new;
end
$$;

create trigger violation_codes_fine_audit
after update of fine_manhattan_south, fine_elsewhere on core.violation_codes
for each row
when (old.fine_manhattan_south is distinct from new.fine_manhattan_south
      or old.fine_elsewhere is distinct from new.fine_elsewhere)
execute function core.log_fine_change();

create function core.plate_history(p_plate text, p_state text default 'NY')
returns table (
    summons_number bigint,
    issue_date date,
    violation_time time,
    violation_code smallint,
    violation text,
    street_name text,
    borough_name text)
language sql stable
as $$
    select v.summons_number, v.issue_date, v.violation_time, v.violation_code, vc.description,
           s.street_name, b.borough_name
    from core.vehicles ve
    join core.violations v on v.vehicle_id = ve.vehicle_id
    join core.violation_codes vc on vc.violation_code = v.violation_code
    left join core.streets s on s.street_id = v.street_id
    left join core.boroughs b on b.borough_id = s.borough_id
    where ve.plate_id = upper(regexp_replace(p_plate, '[^A-Za-z0-9]', '', 'g'))
      and ve.state_code is not distinct from upper(p_state)
    order by v.issue_date, v.violation_time, v.summons_number
$$;

create procedure core.reload_month(p_month date)
language plpgsql
as $$
declare
    month_start date := date_trunc('month', p_month)::date;
    month_end date := (date_trunc('month', p_month) + interval '1 month')::date;
    staged bigint;
    loaded bigint;
begin
    if month_start < etl.window_start() or month_start >= etl.fy_end() then
        raise exception 'month % is outside the load window', month_start;
    end if;

    select count(*)
    into staged
    from etl.stage_violations
    where reject_reason is null and issue_date >= month_start and issue_date < month_end;

    if staged = 0 then
        raise exception 'the stage has no clean rows for %, run the build first', to_char(month_start, 'YYYY-MM');
    end if;

    insert into core.vehicles (
        plate_id, state_code, plate_type_code, make_id, color_id, body_type_id, model_year)
    select
        plate_id,
        state_code,
        mode() within group (order by plate_type_code),
        mode() within group (order by make_id),
        mode() within group (order by color_id),
        mode() within group (order by body_type_id),
        mode() within group (order by model_year)
    from etl.stage_violations
    where reject_reason is null
      and plate_id is not null
      and issue_date >= month_start and issue_date < month_end
    group by plate_id, state_code
    on conflict (plate_id, state_code) do nothing;

    insert into core.streets (borough_id, street_name)
    select borough_id, street_name
    from etl.stage_violations
    where reject_reason is null and street_name is not null
      and issue_date >= month_start and issue_date < month_end
    union
    select borough_id, cross_street_name
    from etl.stage_violations
    where reject_reason is null and cross_street_name is not null
      and issue_date >= month_start and issue_date < month_end
    on conflict (borough_id, street_name) do nothing;

    insert into core.issuers (agency_code, issuer_code)
    select distinct agency_code, issuer_code
    from etl.stage_violations
    where reject_reason is null and issuer_code is not null
      and issue_date >= month_start and issue_date < month_end
    on conflict (agency_code, issuer_code) do nothing;

    execute format('truncate table core.%I', 'violations_' || to_char(month_start, 'YYYY_MM'));

    insert into core.violations
    select *
    from etl.violation_rows
    where issue_date >= month_start and issue_date < month_end
    order by issue_date, summons_number;

    get diagnostics loaded = row_count;
    commit;

    refresh materialized view concurrently mart.daily_tickets;
    refresh materialized view concurrently mart.vehicle_activity;

    raise notice 'reloaded % with % tickets', to_char(month_start, 'YYYY-MM'), loaded;
end
$$;

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'curbside_reader') then
        create role curbside_reader nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'curbside_loader') then
        create role curbside_loader nologin;
    end if;
end
$$;

grant usage on schema core, mart, quality to curbside_reader;
grant select on all tables in schema core, mart, quality to curbside_reader;

do $$
begin
    if not pg_has_role('curbside_loader', 'curbside_reader', 'member') then
        grant curbside_reader to curbside_loader;
    end if;
end
$$;
grant usage on schema raw, etl to curbside_loader;
grant select on all tables in schema raw, etl to curbside_loader;
grant select, insert, update, delete, truncate on all tables in schema core to curbside_loader;
grant usage, select on all sequences in schema core to curbside_loader;
grant execute on all functions in schema etl to curbside_loader;

alter materialized view mart.daily_tickets owner to curbside_loader;
alter materialized view mart.vehicle_activity owner to curbside_loader;

revoke execute on procedure core.reload_month(date) from public;
grant execute on procedure core.reload_month(date) to curbside_loader;
