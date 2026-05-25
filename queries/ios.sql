with ios_sales_reports_subscriber as (
    select
        event_date,
        subscriber_id,
        device,
        developer_proceeds,
		customer_price,
        refund,
        app_apple_id,
        proceeds_currency,
        introductory_price_type,
        proceeds_reason,
        subscription_group_id,
		subscription_apple_id
    from
        mysql_mob_api.ios_sales_reports_subscriber
    where
        event_date <= '2019-12-31'
    union all
    select
        event_date,
        subscriber_id,
        device,
        developer_proceeds,
		customer_price,
        refund,
        app_apple_id,
        proceeds_currency,
        subscription_offer_type as introductory_price_type,
        proceeds_reason,
        subscription_group_id,
		subscription_apple_id
    from
        mysql_mob_api.ios_sales_reports_subscriber_1_2
    where
        event_date > '2019-12-31'
	and
		units > 0
),

usd_first_charge as (
	select
		date,
		subscriber_id,
		subscription_group_id,
		device,
		refund,
		developer_proceeds,
		order_n,
		case
			when refund = 'Yes' then max(coalesce(n, 0)) over(partition by subscriber_id, subscription_group_id order by date, order_n)
			else n
		end as n
	from (
	    select
	        r.event_date as date,
	        r.subscriber_id as subscriber_id,
			r.subscription_apple_id as subscription_group_id,
	        r.device as device,
			r.refund as refund,
	        r.developer_proceeds * case when r.refund = 'Yes' and customer_price < 0 then -1 else 1 end as developer_proceeds,
			case
				when r.refund = 'Yes' then 1
				else 0
			end as order_n,
	        case 
	            when subscriber_id = 0 then 1
				when r.refund = 'Yes' then null
	            else dense_rank() over(partition by r.subscriber_id, r.subscription_apple_id order by r.event_date)
	        end as n
	    from
	        ios_sales_reports_subscriber as r
	    where
	        app_apple_id in (357828853, 1157096263)
	    and
	        r.proceeds_currency = 'USD'
	    and
	        r.introductory_price_type != 'Free Trial'
	)
),

non_usd_first_charge as (
	select
		date,
		subscriber_id,
		subscription_group_id,
		device,
		refund,
		developer_proceeds,
		order_n,
		proceeds_currency,
		case
			when refund = 'Yes' then max(coalesce(n, 0)) over(partition by subscriber_id, subscription_group_id order by date, order_n)
			else n
		end as n
	from (
	    select
	        r.event_date as date,
	        r.subscriber_id as subscriber_id,
			r.subscription_apple_id as subscription_group_id,
	        r.device as device,
			r.refund as refund,
	        r.developer_proceeds * case when r.refund = 'Yes' and customer_price < 0 then -1 else 1 end as developer_proceeds,
			case
				when r.refund = 'Yes' then 1
				else 0
			end as order_n,
	        r.proceeds_currency as proceeds_currency,
	        case 
	            when subscriber_id = 0 then 1
				when r.refund = 'Yes' then null
	            else dense_rank() over(partition by r.subscriber_id, r.subscription_apple_id order by r.event_date)
	        end as n
	    from
	        ios_sales_reports_subscriber as r
	    where
	        app_apple_id in (357828853, 1157096263)
	    and
	        r.proceeds_currency != 'USD'
	    and
	        r.introductory_price_type != 'Free Trial'
	)
),

usd_revenue as (
    select
        date,
        device,
        if(n = 1, 'new', 'recurring') as type,
        sum(developer_proceeds) as revenue
    from
        usd_first_charge
    group by
        date,
        device,
        type
),

non_usd_revenue_1 as (
    select
        date,
        device,
        proceeds_currency,
        if(n = 1, 'new', 'recurring') as type,
        sum(developer_proceeds) as revenue
    from
        non_usd_first_charge
    group by
        date,
        device,
        proceeds_currency,
        type
),

non_usd_revenue_2 as (
    select
        r.date as date,
        r.device as device,
        r.type as type,
        sum(r.revenue / toFloat32OrZero(c.price)) as revenue
    from
        non_usd_revenue_1 as r
    inner join
        mysql_u_guitarcom_ps.currency as c
    on
        toDate(c.date) = r.date
    and
        lower(c.name) = lower(r.proceeds_currency)
    group by
        date,
        device,
        type
),

fact as (
    select
        date as date,
        sum(if(type = 'new', tt.revenue, 0)) as new_revenue,
        sum(if(type = 'recurring', tt.revenue, 0)) as recurrent_revenue,
        sum(tt.revenue) as revenue
    from (
        select
            *
        from
            non_usd_revenue_2
        union all
        select
            *
        from
            usd_revenue
    ) as tt
    where
        date between '{start_date}' and '{end_date}'
    group by
        date
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
        product = 'UG React iOS'
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
        -- os = 'ios'
		product = 'UG' and platform = 'ios'
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
        os = 'ios'
    and
        date between '{start_date}' and '{end_date}'
    group by
        date
)


select
    fact.date as date,
    null as new_plan,
    null as new_base_plan,
    if(fact.new_revenue = 0, null, fact.new_revenue) as new_fact,
    if(fact_paid_ua.revenue = 0, null, fact_paid_ua.revenue) as paid_ua_fact,
    if(crm_fact.revenue = 0, null, crm_fact.revenue) as crm_fact,
    if(fact.new_revenue = 0, null, (fact.new_revenue - coalesce(fact_paid_ua.revenue, 0) - coalesce(crm_fact.revenue, 0))) as new_fact_without_paid_ua_crm,
    null as recurrent_plan,
    if(fact.recurrent_revenue = 0, null, fact.recurrent_revenue) as recurrent_fact,
    null as total_plan,
    if(fact.revenue = 0, null, fact.revenue) as total_fact,
    if(fact.revenue = 0, null, (fact.revenue - coalesce(fact_paid_ua.revenue, 0)  - coalesce(crm_fact.revenue, 0))) as total_fact_without_paid_ua_crm
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
