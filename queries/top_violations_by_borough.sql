with counts as (
    select b.borough_name, v.violation_code, count(*) as tickets
    from core.violations v
    join core.streets s on s.street_id = v.street_id
    join core.boroughs b on b.borough_id = s.borough_id
    group by b.borough_name, v.violation_code
),
ranked as (
    select
        borough_name,
        violation_code,
        tickets,
        rank() over (partition by borough_name order by tickets desc) as rank_in_borough,
        round(100.0 * tickets / sum(tickets) over (partition by borough_name), 1) as pct_of_borough
    from counts
)
select r.borough_name, r.rank_in_borough, r.violation_code, c.description, r.tickets, r.pct_of_borough
from ranked r
join core.violation_codes c on c.violation_code = r.violation_code
where r.rank_in_borough <= 3
order by r.borough_name, r.rank_in_borough;
