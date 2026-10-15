select 'rejected rows' as item, reason as detail, rows as value
from quality.reject_summary
union all
select 'mapping ' || field, method, rows
from quality.mapping_coverage
union all
select 'distinct spellings', 'raw vehicle make', count(*) from etl.make_map
union all
select 'distinct spellings', 'clean vehicle make', count(*) from core.vehicle_makes
union all
select 'distinct spellings', 'raw vehicle color', count(*) from etl.color_map
union all
select 'distinct spellings', 'clean vehicle color', count(*) from core.vehicle_colors
union all
select 'distinct spellings', 'raw county code', count(*) from etl.raw_values where field = 'county'
union all
select 'distinct spellings', 'clean borough', count(*) from core.boroughs
union all
select 'distinct spellings', 'raw street name', count(distinct street_name) from etl.street_texts
union all
select 'distinct spellings', 'clean street', count(*) from core.streets
union all
select 'camera locations', join_rule, sum(rows)::bigint from etl.camera_locations group by join_rule
order by 1, 3 desc;
