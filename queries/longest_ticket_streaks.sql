with days as (
    select distinct v.vehicle_id, v.issue_date
    from core.violations v
    join mart.vehicle_activity a on a.vehicle_id = v.vehicle_id
    where a.ticket_days >= 7
),
islands as (
    select
        vehicle_id,
        issue_date,
        issue_date - (row_number() over (partition by vehicle_id order by issue_date))::integer as island
    from days
),
streaks as (
    select vehicle_id, min(issue_date) as first_day, max(issue_date) as last_day, count(*) as days_in_a_row
    from islands
    group by vehicle_id, island
)
select ve.plate_id, ve.state_code, s.first_day, s.last_day, s.days_in_a_row
from streaks s
join core.vehicles ve on ve.vehicle_id = s.vehicle_id
order by s.days_in_a_row desc, s.first_day
limit 10;
