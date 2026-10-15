with hours as (
    select generate_series(0, 23) as hour
),
counts as (
    select
        extract(hour from violation_time)::integer as hour,
        count(*) filter (where agency_code in ('V', 'M')) as camera,
        count(*) filter (where agency_code not in ('V', 'M')) as handheld
    from core.violations
    where violation_time is not null
    group by 1
)
select
    h.hour,
    coalesce(c.camera, 0) as camera,
    coalesce(c.handheld, 0) as handheld,
    round(100.0 * coalesce(c.handheld, 0) / sum(coalesce(c.handheld, 0)) over (), 2) as handheld_pct
from hours h
left join counts c on c.hour = h.hour
order by h.hour;
