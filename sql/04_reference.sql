create function etl.clean_make(v text) returns text
language sql immutable parallel safe
return nullif(trim(translate(upper(v), '().,*#"', '')), '');

create function etl.to_money(v text) returns numeric
language sql immutable parallel safe
return case
    when regexp_replace(v, '[$,[:space:]]', '', 'g') ~ '^[0-9]{1,5}([.][0-9]{1,2})?$'
    then regexp_replace(v, '[$,[:space:]]', '', 'g')::numeric
end;

create table etl.raw_values as
select
    case
        when grouping(make) = 0 then 'make'
        when grouping(color) = 0 then 'color'
        when grouping(body) = 0 then 'body'
        when grouping(county) = 0 then 'county'
        when grouping(state) = 0 then 'state'
        when grouping(plate_type) = 0 then 'plate_type'
        else 'agency'
    end as field,
    coalesce(make, color, body, county, state, plate_type, agency) as value,
    count(*) as rows
from (
    select
        etl.clean_make(vehicle_make) as make,
        etl.clean_code(vehicle_color) as color,
        etl.clean_code(vehicle_body_type) as body,
        etl.clean_code(violation_county) as county,
        etl.clean_code(registration_state) as state,
        etl.clean_code(plate_type) as plate_type,
        etl.clean_code(issuing_agency) as agency
    from raw.parking_violations
) r
group by grouping sets ((make), (color), (body), (county), (state), (plate_type), (agency));

create table core.boroughs (
    borough_id smallint primary key check (borough_id between 1 and 5),
    borough_name text not null unique
);

insert into core.boroughs (borough_id, borough_name)
select borough_id::smallint, borough_name from etl.seed_boroughs;

create table etl.county_map (
    county_code text primary key,
    borough_id smallint not null references core.boroughs
);

insert into etl.county_map (county_code, borough_id)
select county_code, borough_id::smallint from etl.seed_county_codes;

create table core.registration_states (
    state_code text primary key check (state_code ~ '^[A-Z]{2}$'),
    state_name text not null,
    country text not null check (country in ('US', 'Canada', 'Mexico', 'Other'))
);

insert into core.registration_states (state_code, state_name, country)
select state_code, state_name, country from etl.seed_states;

create table core.plate_types (
    plate_type_code text primary key check (plate_type_code ~ '^[A-Z0-9]{3}$'),
    description text,
    in_dictionary boolean not null
);

insert into core.plate_types (plate_type_code, description, in_dictionary)
select plate_type_code, description, true from etl.seed_plate_types;

insert into core.plate_types (plate_type_code, description, in_dictionary)
select value, null, false
from etl.raw_values
where field = 'plate_type'
  and value ~ '^[A-Z]{3}$'
  and value not in (select plate_type_code from core.plate_types);

create table core.issuing_agencies (
    agency_code text primary key check (agency_code ~ '^[A-Z0-9]$'),
    agency_name text
);

insert into core.issuing_agencies (agency_code, agency_name)
select agency_code, agency_name from etl.seed_agencies;

insert into core.issuing_agencies (agency_code, agency_name)
select value, null
from etl.raw_values
where field = 'agency'
  and value ~ '^[A-Z0-9]$'
  and value not in (select agency_code from core.issuing_agencies);

create table core.violation_codes (
    violation_code smallint primary key check (violation_code between 1 and 99),
    description text not null,
    fine_manhattan_south numeric(7, 2) not null check (fine_manhattan_south >= 0),
    fine_elsewhere numeric(7, 2) not null check (fine_elsewhere >= 0)
);

insert into core.violation_codes (violation_code, description, fine_manhattan_south, fine_elsewhere)
select etl.to_smallint(code), trim(definition), etl.to_money(manhattan_96th_st_below), etl.to_money(all_other_areas)
from raw.violation_codes;

create table core.vehicle_makes (
    make_id smallint generated always as identity primary key,
    make_name text not null unique
);

insert into core.vehicle_makes (make_name)
select distinct make_name from etl.seed_make_codes where make_name <> '' order by 1;

create table etl.make_map (
    raw_value text primary key,
    make_id smallint references core.vehicle_makes,
    method text not null check (method in ('seed', 'placeholder', 'nearest spelling', 'unmapped')),
    hops smallint not null default 0,
    rows bigint not null
);

insert into etl.make_map (raw_value, make_id, method, rows)
select v.value, m.make_id, case when m.make_id is null then 'placeholder' else 'seed' end, v.rows
from etl.raw_values v
join etl.seed_make_codes s on s.code = v.value
left join core.vehicle_makes m on m.make_name = s.make_name
where v.field = 'make';

with recursive
candidates as (
    select value, rows
    from etl.raw_values
    where field = 'make' and value is not null
),
parent as (
    select distinct on (a.value) a.value, b.value as parent
    from candidates a
    join candidates b
      on b.rows >= a.rows * etl.setting('make_match_ratio')::integer
     and left(b.value, etl.setting('make_match_prefix')::integer)
       = left(a.value, etl.setting('make_match_prefix')::integer)
     and abs(length(a.value) - length(b.value)) <= etl.setting('make_match_distance')::integer
     and levenshtein(a.value, b.value) <= etl.setting('make_match_distance')::integer
    where length(a.value) >= 4
      and a.value not in (select raw_value from etl.make_map)
    order by a.value, levenshtein(a.value, b.value), b.rows desc, b.value
),
walk (value, node, hops) as (
    select value, parent, 1 from parent
    union all
    select w.value, p.parent, w.hops + 1
    from walk w
    join parent p on p.value = w.node
    where w.hops < 10
),
resolved as (
    select distinct on (w.value) w.value, m.make_id, w.hops
    from walk w
    join etl.make_map m on m.raw_value = w.node and m.method = 'seed'
    order by w.value, w.hops
)
insert into etl.make_map (raw_value, make_id, method, hops, rows)
select r.value, r.make_id, 'nearest spelling', r.hops, c.rows
from resolved r
join candidates c on c.value = r.value
where r.make_id is not null;

insert into etl.make_map (raw_value, make_id, method, rows)
select value, null, 'unmapped', rows
from etl.raw_values
where field = 'make' and value is not null
  and value not in (select raw_value from etl.make_map);

create table core.vehicle_colors (
    color_id smallint generated always as identity primary key,
    color_name text not null unique
);

insert into core.vehicle_colors (color_name)
select distinct color_name from etl.seed_color_codes where color_name <> '' order by 1;

create table etl.color_map (
    raw_value text primary key,
    color_id smallint references core.vehicle_colors,
    method text not null check (method in ('seed', 'placeholder', 'unmapped')),
    rows bigint not null
);

insert into etl.color_map (raw_value, color_id, method, rows)
select
    v.value,
    c.color_id,
    case when s.code is null then 'unmapped' when c.color_id is null then 'placeholder' else 'seed' end,
    v.rows
from etl.raw_values v
left join etl.seed_color_codes s on s.code = v.value
left join core.vehicle_colors c on c.color_name = s.color_name
where v.field = 'color' and v.value is not null;

create table core.body_types (
    body_type_id smallint generated always as identity primary key,
    body_type_name text not null unique
);

insert into core.body_types (body_type_name)
select distinct body_type_name from etl.seed_body_codes where body_type_name <> '' order by 1;

create table etl.body_map (
    raw_value text primary key,
    body_type_id smallint references core.body_types,
    method text not null check (method in ('seed', 'placeholder', 'unmapped')),
    rows bigint not null
);

insert into etl.body_map (raw_value, body_type_id, method, rows)
select
    v.value,
    b.body_type_id,
    case when s.code is null then 'unmapped' when b.body_type_id is null then 'placeholder' else 'seed' end,
    v.rows
from etl.raw_values v
left join etl.seed_body_codes s on s.code = v.value
left join core.body_types b on b.body_type_name = s.body_type_name
where v.field = 'body' and v.value is not null;
