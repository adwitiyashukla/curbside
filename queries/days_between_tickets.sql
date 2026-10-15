with gaps as (
    select
        v.vehicle_id,
        v.issue_date - lag(v.issue_date) over (partition by v.vehicle_id order by v.issue_date) as gap_days
    from core.violations v
    where v.vehicle_id is not null
),
histogram as (
    select ve.plate_type_code, g.gap_days, count(*) as n
    from gaps g
    join core.vehicles ve on ve.vehicle_id = g.vehicle_id
    where g.gap_days is not null
    group by ve.plate_type_code, g.gap_days
),
running as (
    select
        plate_type_code,
        gap_days,
        n,
        sum(n) over (partition by plate_type_code order by gap_days) as running_n,
        sum(n) over (partition by plate_type_code) as total_n
    from histogram
)
select
    plate_type_code,
    max(total_n) as repeat_tickets,
    min(gap_days) filter (where running_n >= 0.5 * total_n) as median_gap_days,
    min(gap_days) filter (where running_n >= 0.9 * total_n) as p90_gap_days,
    round(sum(gap_days * n)::numeric / max(total_n), 1) as mean_gap_days
from running
group by plate_type_code
having max(total_n) >= 1000
order by repeat_tickets desc;
