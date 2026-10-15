set local client_min_messages = warning;

create schema if not exists raw;

create unlogged table if not exists raw.parking_violations (
    raw_id bigint generated always as identity,
    summons_number text,
    plate_id text,
    registration_state text,
    plate_type text,
    issue_date text,
    violation_code text,
    vehicle_body_type text,
    vehicle_make text,
    issuing_agency text,
    street_code1 text,
    street_code2 text,
    street_code3 text,
    vehicle_expiration_date text,
    violation_location text,
    violation_precinct text,
    issuer_precinct text,
    issuer_code text,
    issuer_command text,
    issuer_squad text,
    violation_time text,
    time_first_observed text,
    violation_county text,
    violation_in_front_of_or_opposite text,
    house_number text,
    street_name text,
    intersecting_street text,
    date_first_observed text,
    law_section text,
    sub_division text,
    violation_legal_code text,
    days_parking_in_effect text,
    from_hours_in_effect text,
    to_hours_in_effect text,
    vehicle_color text,
    unregistered_vehicle text,
    vehicle_year text,
    meter_number text,
    feet_from_curb text,
    violation_post_code text,
    violation_description text,
    no_standing_or_stopping_violation text,
    hydrant_violation text,
    double_parking_violation text,
    fiscal_year text
);

create unlogged table if not exists raw.violation_codes (
    code text,
    definition text,
    manhattan_96th_st_below text,
    all_other_areas text
);

create table if not exists raw.loads (
    load_id bigint generated always as identity primary key,
    file_name text not null,
    table_name text not null,
    row_count bigint not null,
    seconds numeric(10, 2) not null,
    loaded_at timestamptz not null default now()
);
