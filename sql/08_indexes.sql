create index violations_vehicle_idx on core.violations (vehicle_id, issue_date);

create index violations_issue_date_brin on core.violations using brin (issue_date);

create index violations_code_date_idx on core.violations (violation_code, issue_date) include (vehicle_id);

create index violations_hydrant_precinct_idx on core.violations (precinct_id) where violation_code = 40;

create index vehicles_plate_trgm_idx on core.vehicles using gin (plate_id gin_trgm_ops);

create index streets_name_trgm_idx on core.streets using gin (street_name gin_trgm_ops);

analyze core.violations;
analyze core.vehicles;
analyze core.streets;
analyze core.issuers;
