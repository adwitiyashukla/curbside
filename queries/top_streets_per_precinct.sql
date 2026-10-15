with street_counts as materialized (
    select precinct_id, street_id, count(*) as tickets
    from core.violations
    where precinct_id is not null and street_id is not null
    group by precinct_id, street_id
)
select p.precinct_id, b.borough_name, t.street_name, t.tickets
from core.precincts p
join core.boroughs b on b.borough_id = p.borough_id
cross join lateral (
    select s.street_name, c.tickets
    from street_counts c
    join core.streets s on s.street_id = c.street_id
    where c.precinct_id = p.precinct_id
    order by c.tickets desc, s.street_name
    limit 3
) t
order by p.precinct_id, t.tickets desc;
