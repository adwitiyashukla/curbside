set local client_min_messages = warning;

drop schema if exists mart cascade;
drop schema if exists quality cascade;
drop schema if exists core cascade;
drop schema if exists etl cascade;

create schema etl;
create schema core;
create schema quality;
create schema mart;

create extension if not exists pg_trgm;
create extension if not exists fuzzystrmatch;

set local client_min_messages = notice;

do $$
declare
    setting_name text;
begin
    foreach setting_name in array array[
        'fiscal_year', 'late_months', 'profile_sample_percent', 'make_match_distance',
        'make_match_prefix', 'make_match_ratio', 'min_precinct_tickets', 'precinct_majority']
    loop
        execute format(
            'alter database %I set curbside.%s = %L',
            current_database(), setting_name, current_setting('curbside.' || setting_name));
    end loop;
end
$$;

create function etl.setting(name text) returns text
language sql stable parallel safe
return current_setting('curbside.' || name);

create function etl.fy_start() returns date
language sql stable parallel safe
return make_date(etl.setting('fiscal_year')::integer - 1, 7, 1);

create function etl.fy_end() returns date
language sql stable parallel safe
return make_date(etl.setting('fiscal_year')::integer, 7, 1);

create function etl.window_start() returns date
language sql stable parallel safe
return (etl.fy_start() - make_interval(months => etl.setting('late_months')::integer))::date;

create function etl.clean_code(v text) returns text
language sql immutable parallel safe
return nullif(upper(trim(v)), '');

create function etl.to_bigint(v text) returns bigint
language sql immutable parallel safe
return case
    when translate(v, ',0123456789', '') = '' and length(replace(v, ',', '')) between 1 and 18
    then replace(v, ',', '')::bigint
end;

create function etl.to_int(v text) returns integer
language sql immutable parallel safe
return case
    when translate(v, ',0123456789', '') = '' and length(replace(v, ',', '')) between 1 and 9
    then replace(v, ',', '')::integer
end;

create function etl.to_smallint(v text) returns smallint
language sql immutable parallel safe
return case
    when translate(v, ',0123456789', '') = '' and length(replace(v, ',', '')) between 1 and 4
    then replace(v, ',', '')::smallint
end;

create function etl.days_in_month(y integer, m integer) returns integer
language sql immutable parallel safe
return case
    when m in (4, 6, 9, 11) then 30
    when m = 2 and ((y % 4 = 0 and y % 100 <> 0) or y % 400 = 0) then 29
    when m = 2 then 28
    else 31
end;

create function etl.safe_date(y integer, m integer, d integer) returns date
language sql immutable parallel safe
return case
    when y between 1900 and 2100 and m between 1 and 12 and d between 1 and etl.days_in_month(y, m)
    then make_date(y, m, d)
end;

create function etl.parse_mdy(v text) returns date
language sql immutable parallel safe
return case
    when length(v) >= 10 and substr(v, 3, 1) = '/' and substr(v, 6, 1) = '/'
     and translate(substr(v, 1, 2) || substr(v, 4, 2) || substr(v, 7, 4), '0123456789', '') = ''
    then etl.safe_date(substr(v, 7, 4)::integer, substr(v, 1, 2)::integer, substr(v, 4, 2)::integer)
end;

create function etl.parse_ymd(v text) returns date
language sql immutable parallel safe
return case
    when length(replace(v, ',', '')) = 8 and translate(v, ',0123456789', '') = ''
    then etl.safe_date(
        substr(replace(v, ',', ''), 1, 4)::integer,
        substr(replace(v, ',', ''), 5, 2)::integer,
        substr(replace(v, ',', ''), 7, 2)::integer)
end;

create function etl.parse_hhmm(v text) returns time
language sql immutable parallel safe
return case
    when length(v) = 5 and right(v, 1) in ('A', 'P') and translate(left(v, 4), '0123456789', '') = '' then
        case
            when substr(v, 1, 2)::integer <= 12 and substr(v, 3, 2)::integer <= 59
            then make_time(
                substr(v, 1, 2)::integer % 12 + case when right(v, 1) = 'P' then 12 else 0 end,
                substr(v, 3, 2)::integer,
                0)
        end
end;
