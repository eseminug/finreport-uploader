with refunds as (
    select
        ref_dt,
        sumIf(
            case
                when lower(r.currency_of_sale) = 'usd' then 1
                when c.name = '' THEN 0
                else 1
            end * r.refund_amount / coalesce(toDecimal64OrNull(c.price, 10), 1),
            first_order_id = refund_order_id
        ) as new_amount,
        sumIf(
            case
                when lower(r.currency_of_sale) = 'usd' then 1
                when c.name = '' THEN 0
                else 1
            end * r.refund_amount / coalesce(toDecimal64OrNull(c.price, 10), 1),
            first_order_id != refund_order_id
        ) as rec_amount
    from (
        select
            original_order_number,
            ref_dt,
			ref_dt_utc,
            currency_of_sale,
            first_order_id,
            trial,
            duration,
            first_order_dt,
            refund_order_id,
            month_lt,
            case
                when ref_dt < '2022-01-01' then (
                    case
                        when trial = 0 and duration = 12 and order_num >= 0 then refund_amount * 0.85
                        when trial > 0 and duration = 12 and order_num > 0 then refund_amount * 0.85
                        when trial > 0 and duration = 1 and order_num > 11 then refund_amount * 0.85
                        when month_lt > 11 THEN refund_amount * 0.85
                        else refund_amount * 0.7
                    end
                )
                else refund_amount * 0.85
            end as refund_amount
        from (
        select
            original_order_number,
            minIf(toDate(toTimeZone(fromUnixTimestamp(order_charged_timestamp), 'America/Los_Angeles')), financial_status = 'Refund') as ref_dt,
			minIf(toDate(order_charged_timestamp), financial_status = 'Refund') as ref_dt_utc,
            minIf(currency_of_sale, financial_status = 'Refund') as currency_of_sale,
            argMinIf(order_number, order_charged_timestamp, financial_status = 'Charged') as first_order_id,
            argMinIf(p.trial, order_charged_timestamp, financial_status = 'Charged') as trial,
            argMinIf(p.duration, order_charged_timestamp, financial_status = 'Charged') as duration,
            minIf(order_charged_date, financial_status = 'Charged') as first_order_dt,
            argMinIf(order_number, order_charged_timestamp, financial_status = 'Refund') as refund_order_id,
            dateDiff('month', first_order_dt, ref_dt) as month_lt,
            argMinIf(item_price, order_charged_timestamp, financial_status = 'Refund') as refund_amount,
            argMinIf(
                case
                    when length(splitByString('..', s.order_number)) < 2 or splitByString('..', s.order_number)[2] = '' then null
                    else toInt32(splitByString('..', s.order_number)[2])
                end, order_charged_timestamp, financial_status = 'Refund'
            ) as order_num
        from
            mysql_mob_api.android_estimate_sale_report as s
        left join
            mysql_forum.product as p
        on
            p.product_code = s.product_code
        where
            s.product_id in ( 'com.ultimateguitar.tabs', 'com.ultimateguitar.ugpro')
        group by
            original_order_number
        having
            ref_dt > toDate(0)
   --      order by
   --          ref_dt desc,
			-- ref_dt_utc
        )
    ) as r
    left join
        mysql_u_guitarcom_ps.currency as c
    on
        toDate(fromUnixTimestamp(c.date)) = ref_dt_utc
    and
        lower(c.name) = lower(r.currency_of_sale)
    group by
        ref_dt
    order by ref_dt desc
),
-- refunds as (
--     select
--         order_charged_date,
--         order_number,
--         financial_status as type
--     from
--         mysql_mob_api.android_estimate_sale_report
--     where
--         financial_status = 'Refund'
--     and
--         toDate(toTimeZone(fromUnixTimestamp(order_charged_timestamp), 'America/Los_Angeles')) >= '2019-07-01'
--     and
--         product_id in ( 'com.ultimateguitar.tabs', 'com.ultimateguitar.ugpro')
--     group by
--         order_number,
--         financial_status
-- ),
 
 first_purchase_date as (
    select
        order_id,
        payment_account_id,
        min(purchase_time) over (partition by payment_account_id) as first_purchase
    from
        mysql_mob_api.android_transaction
    where
        toDate(toTimeZone(fromUnixTimestamp(purchase_time), 'America/Los_Angeles')) >= '2018-02-20'
),
 
 android_estimate_sale_report as (
    select
        toDate(toTimeZone(fromUnixTimestamp(s.order_charged_timestamp), 'America/Los_Angeles')) as date,
        splitByString('..', s.order_number)[1] as order_id,
        case
            when length(splitByString('..', s.order_number)) < 2 or splitByString('..', s.order_number)[2] = '' then null
            else toInt32(splitByString('..', s.order_number)[2])
        end as order_number,
        dateDiff('month', toDate(toTimeZone(fromUnixTimestamp(t.first_purchase), 'America/Los_Angeles')), toDate(toTimeZone(fromUnixTimestamp(s.order_charged_timestamp), 'America/Los_Angeles'))) as month_lt,
        s.financial_status AS financial_status,
        s.item_price AS price,
        s.currency_of_sale as currency_of_sale,
        -- case
        --     when r.type <> '' then 1
        --     else 0
        -- end as refund,
        p.trial as trial,
        p.duration as duration,
        c.price as currency_price,
        case
            when s.currency_of_sale = 'USD' then s.item_price
            else s.item_price / coalesce(toFloat64OrNull(c.price), 1)
        end as item_price,
        case
            when s.currency_of_sale = 'USD' then s.taxes_collected
            else s.taxes_collected / coalesce(toFloat64OrNull(c.price), 1)
        end as taxes_collected,
        case
            when s.currency_of_sale = 'USD' then s.charged_amount
            else s.charged_amount / coalesce(toFloat64OrNull(c.price), 1)
        end as charged_amount
    from
        mysql_mob_api.android_estimate_sale_report AS s
    left join
        mysql_u_guitarcom_ps.currency AS c 
    on
        c.name = s.currency_of_sale
    and
        toDate(toTimeZone(fromUnixTimestamp(c.date), 'America/Los_Angeles')) = toDate(toTimeZone(fromUnixTimestamp(s.order_charged_timestamp), 'America/Los_Angeles'))
    left join
        mysql_forum.product as p
    on
        p.product_code = s.product_code
    left join
        first_purchase_date as t
    on
        t.order_id = s.original_order_number
    -- left join
    --     refunds as r
    -- on
    --     r.order_number = s.order_number
    where
        toDate(toTimeZone(fromUnixTimestamp(s.order_charged_timestamp), 'America/Los_Angeles')) >= '2019-07-01'
    and
        s.product_id in ('com.ultimateguitar.tabs', 'com.ultimateguitar.ugpro')
),
 
 revenue as (
    select
        date,
        case
            when(order_number = 0 and trial > 0) or (order_number is null and trial = 0) then 'new'
            else 'recurring'
        end as type,
        sum(
            -- case
            --     when refund != 1 then (
                    case
                        when date < '2022-01-01' then (
                            case
                                when trial = 0 and duration = 12 and order_number >= 0 then item_price * 0.85
                                when trial > 0 and duration = 12 and order_number > 0 then item_price * 0.85
                                when trial > 0 and duration = 1 and order_number > 11 then item_price * 0.85
                                when month_lt > 11 THEN item_price * 0.85
                                else item_price * 0.7
                            end
                        )
                        else item_price * 0.85
                    end
            --     )
            -- end
        ) as revenue
    from
        android_estimate_sale_report
    where
        financial_status = 'Charged'
    group by
        date,
        type
),

fact as (
    select
        r.date as date,
        new_revenue - coalesce(new_amount, 0) as new_revenue,
        recurrent_revenue - coalesce(rec_amount, 0) as recurrent_revenue,
        revenue - coalesce(new_amount, 0) - coalesce(rec_amount, 0) as revenue
    from (
    select 
        date as date,
        sum(case when type = 'new' then r.revenue end) as new_revenue,
        sum(case when type = 'recurring' then r.revenue end) as recurrent_revenue,
        sum(r.revenue) as revenue
    from
        revenue as r
    group by
        date
    ) as r
    left join
        refunds as ref
    on
        r.date = ref.ref_dt
),

plan as (
    select
        date,
        sum(t.revenue) as revenue,
        sum(t.new_revenue) + sum(t.action_revenue) as new_revenue,
        sum(t.new_revenue) as new_base_revenue,
        sum(t.recurrent_revenue) as recurrent_revenue
    from
        sandbox.finance_common_daily_financial_plan as t
    where
        date between '{start_date}' and '{end_date}'
    and
        product = 'UG React Android'
  group by
    date
),

fact_paid_ua as (
    select
        date,
        -- sum(net_first_revenue) as revenue
        sum(fact_revenue) as revenue
    from
        -- monetisation_paid_ua.ug_paid_ua_subscriptions_and_costs_agg_by_date_view
        monetisation_paid_ua.paid_ua_common_financial_report_data_view
    where
        -- os = 'android'
        product = 'UG' and platform = 'android'
    and
        date between '{start_date}' and '{end_date}'
    group by
        date
),

crm_fact as (
    select
        date,
        sum(net_first_revenue) as revenue
    from
        monetisation_crm.ug_crm_subscriptions_and_costs_agg_by_date_view
    where
        os = 'android'
    and
        date between '{start_date}' and '{end_date}'
    group by
        date
)


select
    fact.date as date,
    null as new_plan,
    null as new_base_plan,
    fact.new_revenue as new_fact,
    fact_paid_ua.revenue as paid_ua_fact,
    crm_fact.revenue as crm_fact,
    fact.new_revenue - coalesce(fact_paid_ua.revenue, 0) - coalesce(crm_fact.revenue, 0) as new_fact_without_paid_ua_crm,
    null as recurrent_plan,
    fact.recurrent_revenue as recurrent_fact,
    null as total_plan,
    fact.revenue as total_fact,
    fact.revenue - coalesce(fact_paid_ua.revenue, 0)  - coalesce(crm_fact.revenue, 0) as total_fact_without_paid_ua_crm
from
    fact
left join
    fact_paid_ua 
on
    fact.date = fact_paid_ua.date
left join
    crm_fact 
on
    fact.date = crm_fact.date
where
    fact.date between '{start_date}' and '{end_date}'
order by
    fact.date
