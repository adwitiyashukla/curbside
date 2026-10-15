create table core.vehicles (
    vehicle_id integer generated always as identity,
    plate_id text not null check (plate_id ~ '^[A-Z0-9]{1,10}$'),
    state_code text,
    plate_type_code text,
    make_id smallint,
    color_id smallint,
    body_type_id smallint,
    model_year smallint check (model_year between 1950 and 2100)
);

insert into core.vehicles (plate_id, state_code, plate_type_code, make_id, color_id, body_type_id, model_year)
select
    plate_id,
    state_code,
    mode() within group (order by plate_type_code),
    mode() within group (order by make_id),
    mode() within group (order by color_id),
    mode() within group (order by body_type_id),
    mode() within group (order by model_year)
from etl.stage_violations
where reject_reason is null and plate_id is not null
group by plate_id, state_code;

alter table core.vehicles
    add constraint vehicles_pkey primary key (vehicle_id),
    add constraint vehicles_plate_state_key unique nulls not distinct (plate_id, state_code),
    add constraint vehicles_state_fkey foreign key (state_code) references core.registration_states,
    add constraint vehicles_plate_type_fkey foreign key (plate_type_code) references core.plate_types,
    add constraint vehicles_make_fkey foreign key (make_id) references core.vehicle_makes,
    add constraint vehicles_color_fkey foreign key (color_id) references core.vehicle_colors,
    add constraint vehicles_body_type_fkey foreign key (body_type_id) references core.body_types;

create table core.issuers (
    issuer_id integer generated always as identity primary key,
    agency_code text not null references core.issuing_agencies,
    issuer_code integer not null check (issuer_code > 0),
    constraint issuers_agency_code_key unique (agency_code, issuer_code)
);

insert into core.issuers (agency_code, issuer_code)
select distinct agency_code, issuer_code
from etl.stage_violations
where reject_reason is null and issuer_code is not null
order by 1, 2;

create table core.precincts (
    precinct_id smallint primary key check (precinct_id between 1 and 999),
    borough_id smallint not null references core.boroughs
);

insert into core.precincts (precinct_id, borough_id)
select precinct, borough_id
from (
    select
        precinct,
        borough_id,
        count(*) as tickets,
        sum(count(*)) over (partition by precinct) as precinct_tickets,
        row_number() over (partition by precinct order by count(*) desc, borough_id) as rank
    from etl.stage_violations
    where reject_reason is null and precinct is not null and borough_id is not null
    group by precinct, borough_id
) s
where rank = 1
  and precinct_tickets >= etl.setting('min_precinct_tickets')::integer
  and tickets >= etl.setting('precinct_majority')::numeric * precinct_tickets;

create table core.streets (
    street_id integer generated always as identity primary key,
    borough_id smallint references core.boroughs,
    street_name text not null,
    constraint streets_borough_name_key unique nulls not distinct (borough_id, street_name)
);

insert into core.streets (borough_id, street_name)
select borough_id, street_name
from (
    select borough_id, street_name
    from etl.stage_violations
    where reject_reason is null and street_name is not null
    union
    select borough_id, cross_street_name
    from etl.stage_violations
    where reject_reason is null and cross_street_name is not null
) s
order by borough_id, street_name;

create view etl.violation_rows as
select
    s.raw_id,
    s.summons_number,
    s.issue_date,
    s.violation_time,
    v.vehicle_id,
    s.violation_code,
    s.agency_code,
    i.issuer_id,
    s.issuer_command,
    s.issuer_squad,
    p.precinct_id,
    s.issuer_precinct,
    st.street_id,
    cs.street_id as cross_street_id,
    s.house_number,
    s.street_side,
    s.front_or_opposite,
    s.location_note,
    s.camera_direction,
    s.law_section,
    s.sub_division,
    s.registration_expires,
    s.date_first_observed,
    s.time_first_observed,
    s.feet_from_curb,
    s.meter_number
from etl.stage_violations s
left join core.vehicles v
  on v.plate_id = s.plate_id and v.state_code is not distinct from s.state_code
left join core.issuers i
  on i.agency_code = s.agency_code and i.issuer_code = s.issuer_code
left join core.precincts p on p.precinct_id = s.precinct
left join core.streets st
  on st.street_name = s.street_name and st.borough_id is not distinct from s.borough_id
left join core.streets cs
  on cs.street_name = s.cross_street_name and cs.borough_id is not distinct from s.borough_id
where s.reject_reason is null;
