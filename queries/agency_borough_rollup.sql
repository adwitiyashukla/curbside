select
    case when grouping(a.agency_name) = 1 then 'ALL AGENCIES' else coalesce(a.agency_name, a.agency_code) end
        as agency,
    case when grouping(b.borough_name) = 1 then 'ALL BOROUGHS' else coalesce(b.borough_name, 'unknown') end
        as borough,
    count(*) as tickets
from core.violations v
join core.issuing_agencies a on a.agency_code = v.agency_code
left join core.streets s on s.street_id = v.street_id
left join core.boroughs b on b.borough_id = s.borough_id
group by rollup ((a.agency_code, a.agency_name), b.borough_name)
having count(*) >= 10000 or grouping(b.borough_name) = 1
order by grouping(a.agency_name), agency, grouping(b.borough_name), tickets desc;
