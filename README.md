# finreport-uploader

Builds daily revenue plan CSV files for a selected month using ClickHouse fact queries.

## Requirements

- Python 3.13
- Dependencies from `requirements.txt`
- A `.env` file with ClickHouse connection settings:

```env
CLICKHOUSE_HOST=...
CLICKHOUSE_PORT=8443
CLICKHOUSE_USERNAME=...
CLICKHOUSE_PASSWORD=...
```

## Usage

```bash
.venv/bin/python main.py 2026-06-01 --output-dir output
```

The month argument must be the first day of the analyzed month in `YYYY-MM-DD` format. For example, `2026-06-01` builds the plan for June 2026.

The script writes two semicolon-separated CSV files:

- `daily_revenue_plan_YYYY-MM.csv`
- `summary_revenue_plan_YYYY-MM.csv`

## Data Window

For a selected month, the script loads one ClickHouse range covering all required prior-year dates. For June 2026, it queries facts from `2025-06-01` through `2025-07-01`.

This range is needed because:

- new revenue for iOS, Android, and the draft Web calculation uses the target date minus 364 days;
- recurrent revenue uses the target date minus 365 days;
- the summary fact baseline uses the same month in the previous year.

## ClickHouse Queries

The source SQL files live in `queries/`:

- `ios.sql`
- `android.sql`
- `web.sql`

Each query accepts:

- `{start_date}`
- `{end_date}`

The iOS, Android, and Web outputs include `new_fact_without_paid_ua_crm` and `recurrent_fact`. The Web query also contains the CRM fact slice used for `CRM UG Web`.

## Daily Plan Logic

The daily output has these columns:

```text
date;product;revenue;new_revenue;recurrent_revenue;base_revenue;action_revenue
```

Products:

- `UG React iOS`
- `UG React Android`
- `UG React Web`
- `CRM UG Web`

For iOS and Android:

- `new_revenue = new_fact_without_paid_ua_crm(date - 364 days) * 1.04`
- `recurrent_revenue = recurrent_fact(date - 365 days) * 1.04`

For CRM:

- `new_revenue = crm_fact(date - 365 days)`
- `recurrent_revenue = 0`

For Web:

- draft `new_revenue = new_fact_without_paid_ua_crm(date - 364 days) * 1.04`
- `recurrent_revenue = new_fact_without_paid_ua_crm(date - 365 days) * 0.6399 + recurrent_fact(date - 365 days) * 0.7487`
- final Web new revenue is scaled so that monthly Web base revenue equals previous-year Web fact multiplied by `1.04`, after subtracting the calculated recurrent revenue.

For every product and day:

- `base_revenue = new_revenue + recurrent_revenue`
- `revenue = base_revenue + action_revenue`

All daily numeric values are rounded to integers before writing the CSV.

## Summary Logic

The summary output has these columns:

```text
product;YYYY fact;new;recurring;base;y-o-y;y-o-y, %;action;total plan
```

For each product:

- `YYYY fact` is the previous-year same-month fact baseline;
- `new` is the monthly sum of calculated `new_revenue`;
- `recurring` is the monthly sum of calculated `recurrent_revenue`;
- `base = new + recurring`;
- `y-o-y = base - YYYY fact`;
- `y-o-y, % = (base - YYYY fact) / base * 100`;
- `total plan = YYYY fact * 1.25`;
- `action = total plan - base`.

The summary includes two total rows:

- `UG React Total`, which aggregates iOS, Android, and Web only;
- `Total`, which aggregates all products including CRM.

`action_revenue` in the daily file is calculated by dividing each product's summary `action` value by the number of days in the analyzed month.
