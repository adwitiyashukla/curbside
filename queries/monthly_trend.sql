with monthly as (
    select date_trunc('month', issue_date)::date as month, count(*) as tickets
    from core.violations
    group by 1
)
select
    month,
    tickets,
    tickets - lag(tickets) over (order by month) as change,
    round(100.0 * (tickets - lag(tickets) over (order by month))
          / nullif(lag(tickets) over (order by month), 0), 1) as change_pct,
    sum(tickets) over (order by month rows between unbounded preceding and current row) as running_total
from monthly
order by month;
