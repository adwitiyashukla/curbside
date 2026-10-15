create view core.violation_details as
select
    v.summons_number,
    v.issue_date,
    v.violation_time,
    v.violation_code,
    vc.description as violation,
    a.agency_name,
    b.borough_name,
    v.precinct_id,
    s.street_name,
    cs.street_name as cross_street_name,
    v.house_number,
    ve.plate_id,
    ve.state_code,
    ve.plate_type_code,
    mk.make_name,
    co.color_name,
    bt.body_type_name,
    ve.model_year
from core.violations v
join core.violation_codes vc on vc.violation_code = v.violation_code
join core.issuing_agencies a on a.agency_code = v.agency_code
left join core.streets s on s.street_id = v.street_id
left join core.boroughs b on b.borough_id = s.borough_id
left join core.streets cs on cs.street_id = v.cross_street_id
left join core.vehicles ve on ve.vehicle_id = v.vehicle_id
left join core.vehicle_makes mk on mk.make_id = ve.make_id
left join core.vehicle_colors co on co.color_id = ve.color_id
left join core.body_types bt on bt.body_type_id = ve.body_type_id;

create materialized view mart.daily_tickets as
select
    v.issue_date,
    s.borough_id,
    v.violation_code,
    count(*) as tickets
from core.violations v
left join core.streets s on s.street_id = v.street_id
group by v.issue_date, s.borough_id, v.violation_code;

create unique index daily_tickets_key on mart.daily_tickets (issue_date, borough_id, violation_code)
    nulls not distinct;

create materialized view mart.vehicle_activity as
select
    vehicle_id,
    count(*) as tickets,
    count(distinct violation_code) as distinct_codes,
    min(issue_date) as first_ticket,
    max(issue_date) as last_ticket,
    count(distinct issue_date) as ticket_days
from core.violations
where vehicle_id is not null
group by vehicle_id;

create unique index vehicle_activity_key on mart.vehicle_activity (vehicle_id);
create index vehicle_activity_tickets_idx on mart.vehicle_activity (tickets desc);

analyze mart.daily_tickets;
analyze mart.vehicle_activity;
