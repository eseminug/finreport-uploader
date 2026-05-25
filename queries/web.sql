WITH
braintree_tr as (
    select
        payment_account_id,
        product_code,
        transaction_id,
        uniqExact(transaction_id) over(partition by braintree_subscription_id) as transaction_cnt
    from
        monetisation_ug.braintree_transaction
    where
        transaction_id != ''
),
refunds as (
    select
        toDate(date_braintree_created, 'America/Los_Angeles') as dt,
        sumIf(
            case
                when lower(r.currency) = 'usd' then 1
                when c.name = '' THEN 0
                else 1
            end * r.amount / coalesce(toDecimal64OrNull(c.price, 10), 1),
            transaction_cnt = 1
        ) as new_amount,
        sumIf(
            case
                when lower(r.currency) = 'usd' then 1
                when c.name = '' THEN 0
                else 1
            end * r.amount / coalesce(toDecimal64OrNull(c.price, 10), 1),
            transaction_cnt > 1
        ) as rec_amount,
        sum(
            case
                when lower(r.currency) = 'usd' then 1
                when c.name = '' THEN 0
                else 1
            end * r.amount / coalesce(toDecimal64OrNull(c.price, 10), 1)
        ) as amount
    from
        mysql_u_guitarcom_ps.braintree_refund as r
    inner join
        braintree_tr as t
    on
        r.transaction_id = t.transaction_id
    left join
        mysql_u_guitarcom_ps.currency as c
    on
        toDate(fromUnixTimestamp(c.date)) = toDate(fromUnixTimestamp(r.date_braintree_created))
    and
        lower(c.name) = lower(r.currency)
    group by
        dt
),

revenue AS (
SELECT
    -- toDate(date_transaction, 'America/Los_Angeles') AS date
    date_transaction as date
  , payment_method
  , amount
--   , amount - coalesce(r.amount, 0) as amount_wo_refunds
  , rank() over(partition by t.braintree_subscription_id order by date_transaction) as billing_cycle
FROM
  (
    SELECT
        payment_account_id
		, braintree_subscription_id
        , id as transaction_id
      , 'braintree' AS ps
      , product_code
      , date_transaction
      , payment_method
      , amount
    FROM monetisation_ug.braintree_vindicia_twp_transaction
    WHERE amount > 0
      AND trial = 0
	-- за вычетом комиссий пейпала
    UNION ALL
    SELECT
       t.payment_account_id as payment_account_id
	   , t.braintree_subscription_id as braintree_subscription_id
       , t.transaction_id as transaction_id
      , 'braintree' AS ps
      , t.product_code as product_code
      , t.date_transaction as date_transaction
      , t.payment_method as payment_method
   --    , t.amount - case
   --  		when lower(f.fee_currency) = 'usd' then 1
   --          when c.name = '' THEN 0
   --          else 1
   --      end * f.fee_amount / coalesce(toDecimal64OrNull(c.price, 10), 1)
	  -- as amount
	  , t.amount as amount
    FROM monetisation_ug.braintree_transaction as t
	-- LEFT JOIN
	-- 	mysql_u_guitarcom_ps.braintree_paypal_fee as f
	-- ON
	-- 	t.transaction_id = f.transaction_id
	-- LEFT JOIN
	-- 	mysql_u_guitarcom_ps.currency as c
 --    ON
 --        toDate(fromUnixTimestamp(c.date)) = t.date_transaction
 --    AND
 --        lower(c.name) = lower(f.fee_currency)	
    WHERE t.amount > 0
      AND t.trial = 0
    UNION ALL
    SELECT
      payment_account_id
	  , subscription_id as braintree_subscription_id
      , id as transaction_id
      , 'stripe' AS ps
      , product_code
      , date_transaction
      , 'CreditCard' as payment_method
      , amount
    FROM monetisation_ug.stripe_transaction
    WHERE amount > 0
      AND trial = 0
    UNION ALL
    SELECT
       payment_account_id
	   , toString(subscription_id) as braintree_subscription_id
       , toString(id) as transaction_id
      , 'vindicia' AS ps
      , product_code
      , toDate(date_transaction, 'America/Los_Angeles')
      , payment_method
      , amount
    FROM monetisation_ug.vindicia_transaction
    WHERE amount > 0
      AND trial = 0
  ) t
WHERE
    product_code IN (
                    SELECT uw.product_code
                    FROM monetisation_ug.ug_react_web uw
                    )
  ),

fact as (
    select
        t.date as date,
        t.new_revenue - coalesce(r.new_amount, 0) as new_revenue,
        t.new_revenue as new_revenue_refunds,
        t.recurrent_revenue - coalesce(r.rec_amount, 0) as recurrent_revenue,
        t.recurrent_revenue as recurrent_revenue_refuds,
        t.revenue - coalesce(r.new_amount, 0) - coalesce(r.rec_amount, 0) as revenue
    from (
        select 
            date as date,
            sum(case when billing_cycle = 1 then amount else 0 end) as new_revenue,
            sum(case when billing_cycle > 1 then amount else 0 end) as recurrent_revenue,
            sum(amount) as revenue
        from
            revenue as r
        group by
            date
    ) as t
    left join
        refunds as r
    on
        t.date = r.dt
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
	-- date between '2025-01-01' and '2025-12-31'
    and
        product = 'UG React Web'
  group by
    date
),

fact_paid_ua as (
    select
        date,
        -- sum(net_first_revenue) as revenue
		sum(fact_revenue) as revenue
    from
        -- monetisation_paid_ua.ug_paid_ua_subscriptions_and_costs_agg_by_date_view_dbt
		monetisation_paid_ua.paid_ua_common_financial_report_data_view
    where
        -- os = 'web'
		product = 'UG' and platform = 'web'
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
        -- monetisation_crm.ug_crm_subscriptions_and_costs_agg_by_date_view
		monetisation_paid_ua.ug_marketing_subscriptions_and_costs_agg_by_date_view_dbt
    where
        os = 'web'
    and
        date between '{start_date}' and '{end_date}'
	and
		medium = 'CRM'
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
    -- crm_fact.revenue  as crm_fact,
    -- if(plan.date <= today() - 2, (fact.new_revenue - coalesce(fact_paid_ua.revenue, 0) - coalesce(crm_fact.revenue, 0)), null) as new_fact_without_paid_ua_crm_refunds,
    -- if(plan.date <= today() - 2, (fact.new_revenue_refunds - coalesce(fact_paid_ua.revenue, 0) - coalesce(crm_fact.revenue, 0)), null) as new_fact_without_paid_ua_crm,
	fact.new_revenue - coalesce(fact_paid_ua.revenue, 0) - coalesce(crm_fact.revenue, 0) as new_fact_without_paid_ua_crm,
    null as recurrent_plan,
    fact.recurrent_revenue as recurrent_fact,
    -- if(plan.date <= today() - 2, fact.recurrent_revenue_refuds, null) as recurrent_fact_without_refunds,
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
