create function etl.valid_plate(p text) returns text
language sql immutable parallel safe
return case
    when p in ('BLANKPLATE', 'BLANK', 'NOPLATE', 'NONE', 'UNKNOWN') then null
    when length(p) between 1 and 10 and translate(p, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', '') = ''
    then p
end;

create function etl.clean_plate(v text) returns text
language sql immutable parallel safe
return etl.valid_plate(translate(upper(v), ' -./,', ''));

create function etl.normalize_street(v text) returns text
language sql immutable parallel safe
return nullif(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
        trim(regexp_replace(regexp_replace(upper(v), '[.,'']', '', 'g'), '\s+', ' ', 'g')),
        '\m([0-9]+)(ST|ND|RD|TH)\M', '\1', 'g'),
        '^EAST ([0-9])', 'E \1'),
        '^WEST ([0-9])', 'W \1'),
        '\mSTREET\M', 'ST', 'g'),
        '\mAVENUE\M|\mAV\M', 'AVE', 'g'),
        '\mPLACE\M', 'PL', 'g'),
        '\mROAD\M', 'RD', 'g'),
        '\mBOULEVARD\M|\mBLV\M', 'BLVD', 'g'),
        '\mPARKWAY\M|\mPKY\M', 'PKWY', 'g'),
        '\mDRIVE\M', 'DR', 'g'),
        '\mCOURT\M', 'CT', 'g'),
        '\mLANE\M', 'LN', 'g'),
        '\mEXPRESSWAY\M|\mEXPWY\M|\mEXWY\M', 'EXPY', 'g'),
        '\mHIGHWAY\M', 'HWY', 'g'),
        '^B ?WAY$|^BDWY$', 'BROADWAY'),
    '');

create function etl.last_word(v text) returns text
language sql immutable parallel safe
return upper(substring(v from '([^ ]+)$'));

create function etl.first_word(v text) returns text
language sql immutable parallel safe
return upper(substring(v from '^([^ ]+)'));

create table etl.street_texts as
select
    coalesce(issuing_agency in ('V', 'M'), false) as camera,
    street_name,
    case when issuing_agency in ('V', 'M') then intersecting_street end as intersecting_street,
    count(*) as rows
from raw.parking_violations
group by 1, 2, 3;

create table etl.street_words as
select word, sum(rows) as freq
from etl.street_texts t
cross join lateral regexp_split_to_table(upper(trim(t.street_name)), '\s+') as word
where not t.camera and word <> ''
group by word;

create unique index on etl.street_words (word);

create table etl.camera_locations as
with pairs as (
    select street_name as part1, intersecting_street as part2, rows
    from etl.street_texts
    where camera and street_name is not null
),
scored as (
    select
        p.*,
        etl.last_word(p.part1) as left_word,
        etl.first_word(p.part2) as right_word,
        coalesce((select freq from etl.street_words where word = etl.last_word(p.part1)), 0) as left_freq,
        coalesce((select freq from etl.street_words where word = etl.first_word(p.part2)), 0) as right_freq,
        coalesce((select freq from etl.street_words
                  where word = etl.last_word(p.part1) || etl.first_word(p.part2)), 0) as joined_freq
    from pairs p
),
decided as (
    select
        s.*,
        case
            when part2 is null then 'single field'
            when length(part1) < 20 then 'first half was short'
            when part2 like '@%' or part1 like '%@' then 'at sign at the cut'
            when part1 ~ '[(/]$' or part2 ~ '^[/)]' then 'bracket across the cut'
            when part1 ~ '[0-9]$' and part2 ~ '^[0-9]' then 'digits across the cut'
            when part1 ~ '[0-9]$' and part2 ~* '^(st|nd|rd|th)\M' then 'ordinal after the cut'
            when part1 ~ '[a-z]$' and part2 ~ '^[a-z]' then 'lowercase across the cut'
            when part1 ~ '[a-z]$' and part2 ~ '^[A-Z]' then 'new capital after the cut'
            when joined_freq > 0 and (left_freq = 0 or right_freq = 0) then 'joined word is known'
            when joined_freq = 0 and left_freq > 0 and right_freq > 0 then 'both halves are known'
            when joined_freq = 0 and left_freq = 0 and right_freq = 0 then 'both halves are fragments'
            when joined_freq > least(left_freq, right_freq) then 'joined word is more common'
            else 'default space'
        end as join_rule
    from scored s
),
joined as (
    select
        d.*,
        case
            when part2 is null then part1
            when join_rule in (
                'bracket across the cut', 'digits across the cut', 'ordinal after the cut',
                'lowercase across the cut', 'joined word is known', 'both halves are fragments',
                'joined word is more common')
                then part1 || part2
            else part1 || ' ' || part2
        end as location
    from decided d
),
parsed as (
    select
        j.*,
        coalesce(
            substring(upper(location) from '^([NSEW])B '),
            substring(upper(location) from '\(([NSEW])/B\)')) as direction,
        trim(regexp_replace(regexp_replace(upper(location), '^[NSEW]B ', ''), '\s*\([NSEW]/B\)', '', 'g'))
            as bare
    from joined j
)
select
    part1,
    part2,
    rows,
    join_rule,
    location,
    direction,
    etl.normalize_street(split_part(bare, '@', 1)) as on_street,
    etl.normalize_street(nullif(split_part(bare, '@', 2), '')) as cross_street
from parsed;

create unique index on etl.camera_locations (part1, part2) nulls not distinct;

create table etl.street_map as
select street_name as raw_value, etl.normalize_street(street_name) as street_name, sum(rows) as rows
from etl.street_texts
where not camera and street_name is not null
group by street_name;

create unique index on etl.street_map (raw_value);

create unlogged table etl.stage_violations as
select
    r.raw_id,
    etl.to_bigint(r.summons_number) as summons_number,
    etl.parse_mdy(r.issue_date) as issue_date,
    etl.parse_hhmm(r.violation_time) as violation_time,
    etl.clean_plate(r.plate_id) as plate_id,
    rs.state_code,
    pt.plate_type_code,
    mm.make_id,
    cm.color_id,
    bm.body_type_id,
    case
        when etl.to_smallint(r.vehicle_year) between 1950 and etl.setting('fiscal_year')::integer + 1
        then etl.to_smallint(r.vehicle_year)
    end as model_year,
    vc.violation_code,
    ag.agency_code,
    nullif(etl.to_int(r.issuer_code), 0) as issuer_code,
    etl.clean_code(r.issuer_command) as issuer_command,
    etl.clean_code(r.issuer_squad) as issuer_squad,
    nullif(etl.to_smallint(r.violation_precinct), 0) as precinct,
    nullif(etl.to_smallint(r.issuer_precinct), 0) as issuer_precinct,
    cty.borough_id,
    coalesce(cl.on_street, sm.street_name) as street_name,
    cl.cross_street as cross_street_name,
    cl.direction as camera_direction,
    case when etl.clean_code(r.house_number) not in ('N', 'S', 'E', 'W') then etl.clean_code(r.house_number) end
        as house_number,
    case when etl.clean_code(r.house_number) in ('N', 'S', 'E', 'W') then etl.clean_code(r.house_number) end
        as street_side,
    etl.clean_code(r.violation_in_front_of_or_opposite) as front_or_opposite,
    case when cl.part1 is null then etl.clean_code(r.intersecting_street) end as location_note,
    nullif(etl.to_smallint(r.law_section), 0) as law_section,
    etl.clean_code(r.sub_division) as sub_division,
    etl.parse_ymd(r.vehicle_expiration_date) as registration_expires,
    etl.parse_ymd(r.date_first_observed) as date_first_observed,
    etl.parse_hhmm(r.time_first_observed) as time_first_observed,
    nullif(etl.to_smallint(r.feet_from_curb), 0) as feet_from_curb,
    case when translate(r.meter_number, '0123456789', '') <> r.meter_number then etl.clean_code(r.meter_number) end
        as meter_number,
    null::text as reject_reason
from raw.parking_violations r
left join core.registration_states rs on rs.state_code = etl.clean_code(r.registration_state)
left join core.plate_types pt on pt.plate_type_code = etl.clean_code(r.plate_type)
left join etl.make_map mm on mm.raw_value = etl.clean_make(r.vehicle_make)
left join etl.color_map cm on cm.raw_value = etl.clean_code(r.vehicle_color)
left join etl.body_map bm on bm.raw_value = etl.clean_code(r.vehicle_body_type)
left join core.violation_codes vc on vc.violation_code = etl.to_smallint(r.violation_code)
left join core.issuing_agencies ag on ag.agency_code = etl.clean_code(r.issuing_agency)
left join etl.county_map cty on cty.county_code = etl.clean_code(r.violation_county)
left join etl.camera_locations cl
  on r.issuing_agency in ('V', 'M')
 and cl.part1 = r.street_name
 and cl.part2 is not distinct from r.intersecting_street
left join etl.street_map sm
  on not coalesce(r.issuing_agency in ('V', 'M'), false)
 and sm.raw_value = r.street_name;

update etl.stage_violations
set reject_reason = case
    when summons_number is null then 'bad summons number'
    when issue_date is null then 'bad issue date'
    when issue_date < etl.window_start() then 'issue date before load window'
    when issue_date >= etl.fy_end() then 'issue date after fiscal year'
    when violation_code is null then 'unknown violation code'
    else 'unknown issuing agency'
end
where summons_number is null
   or issue_date is null
   or issue_date < etl.window_start()
   or issue_date >= etl.fy_end()
   or violation_code is null
   or agency_code is null;

update etl.stage_violations
set date_first_observed = null
where date_first_observed > issue_date;

with ranked as (
    select raw_id, row_number() over (partition by summons_number order by raw_id) as copy_number
    from etl.stage_violations
    where reject_reason is null
      and summons_number in (
          select summons_number
          from etl.stage_violations
          where reject_reason is null
          group by summons_number
          having count(*) > 1)
)
update etl.stage_violations s
set reject_reason = 'duplicate summons number'
from ranked d
where d.raw_id = s.raw_id and d.copy_number > 1;

create index on etl.stage_violations (issue_date) where reject_reason is null;

analyze etl.stage_violations;
