create table core.violations (
    raw_id bigint not null,
    summons_number bigint not null,
    issue_date date not null,
    violation_time time,
    vehicle_id integer,
    violation_code smallint not null,
    agency_code text not null,
    issuer_id integer,
    issuer_command text,
    issuer_squad text,
    precinct_id smallint,
    issuer_precinct smallint,
    street_id integer,
    cross_street_id integer,
    house_number text,
    street_side text,
    front_or_opposite text,
    location_note text,
    camera_direction text,
    law_section smallint,
    sub_division text,
    registration_expires date,
    date_first_observed date,
    time_first_observed time,
    feet_from_curb smallint,
    meter_number text
) partition by range (issue_date);

do $$
declare
    month_start date;
begin
    for month_start in
        select generate_series(etl.window_start(), etl.fy_end() - 1, interval '1 month')::date
    loop
        execute format(
            'create table core.%I partition of core.violations for values from (%L) to (%L)',
            'violations_' || to_char(month_start, 'YYYY_MM'),
            month_start,
            (month_start + interval '1 month')::date);
    end loop;
end
$$;

insert into core.violations
select * from etl.violation_rows
order by issue_date, summons_number;

alter table core.violations
    add constraint violations_pkey primary key (summons_number, issue_date),
    add constraint violations_vehicle_fkey foreign key (vehicle_id) references core.vehicles,
    add constraint violations_code_fkey foreign key (violation_code) references core.violation_codes,
    add constraint violations_agency_fkey foreign key (agency_code) references core.issuing_agencies,
    add constraint violations_issuer_fkey foreign key (issuer_id) references core.issuers,
    add constraint violations_precinct_fkey foreign key (precinct_id) references core.precincts,
    add constraint violations_street_fkey foreign key (street_id) references core.streets,
    add constraint violations_cross_street_fkey foreign key (cross_street_id) references core.streets,
    add constraint violations_street_side_check check (street_side in ('N', 'S', 'E', 'W')),
    add constraint violations_camera_direction_check check (camera_direction in ('N', 'S', 'E', 'W')),
    add constraint violations_feet_check check (feet_from_curb between 1 and 999),
    add constraint violations_dates_check check (date_first_observed <= issue_date);
