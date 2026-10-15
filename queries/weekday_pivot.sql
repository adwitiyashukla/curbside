select
    v.violation_code,
    c.description,
    count(*) filter (where extract(isodow from v.issue_date) = 1) as mon,
    count(*) filter (where extract(isodow from v.issue_date) = 2) as tue,
    count(*) filter (where extract(isodow from v.issue_date) = 3) as wed,
    count(*) filter (where extract(isodow from v.issue_date) = 4) as thu,
    count(*) filter (where extract(isodow from v.issue_date) = 5) as fri,
    count(*) filter (where extract(isodow from v.issue_date) = 6) as sat,
    count(*) filter (where extract(isodow from v.issue_date) = 7) as sun,
    count(*) as total
from core.violations v
join core.violation_codes c on c.violation_code = v.violation_code
group by v.violation_code, c.description
order by total desc
limit 10;
