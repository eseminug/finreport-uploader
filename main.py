from __future__ import annotations

import argparse
import calendar
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv

from clickhouse_worker import execute_sql, get_query

load_dotenv()


GROWTH_FACTOR = 1.04
TOTAL_PLAN_FACTOR = 1.25
WEB_RECURRENT_NEW_FACTOR = 0.6399
WEB_RECURRENT_REC_FACTOR = 0.7487


@dataclass(frozen=True)
class Platform:
    query_name: str
    product: str


PLATFORMS = {
    "ios": Platform("ios", "UG React iOS"),
    "android": Platform("android", "UG React Android"),
    "web": Platform("web", "UG React Web"),
}

CRM_PRODUCT = "CRM UG Web"
UG_REACT_PRODUCTS = [PLATFORMS["ios"].product, PLATFORMS["android"].product, PLATFORMS["web"].product]


def parse_month(value: str) -> date:
    try:
        month = datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError as exc:
        raise argparse.ArgumentTypeError("Month must be passed as YYYY-MM-DD, for example 2026-06-01.") from exc

    if month.day != 1:
        raise argparse.ArgumentTypeError("Month date must be the first day of a month.")
    return month


def month_bounds(month: date) -> tuple[date, date]:
    last_day = calendar.monthrange(month.year, month.month)[1]
    return month, date(month.year, month.month, last_day)


def date_key(value) -> date:
    if isinstance(value, date):
        return value
    return pd.to_datetime(value).date()


def value_by_date(df: pd.DataFrame, column: str, day: date) -> float:
    if df.empty or column not in df.columns:
        return 0.0

    rows = df.loc[df["date"] == day, column]
    if rows.empty or pd.isna(rows.iloc[0]):
        return 0.0
    return float(rows.iloc[0])


def run_platform_query(platform: Platform, start_date: date, end_date: date) -> pd.DataFrame:
    sql = get_query(
        platform.query_name,
        {
            "start_date": start_date.isoformat(),
            "end_date": end_date.isoformat(),
        },
    )
    df = execute_sql(sql, max_rows=100_000)
    if df.empty:
        return pd.DataFrame(columns=["date"])

    df = df.copy()
    df["date"] = df["date"].map(date_key)
    return df


def build_mobile_rows(platform: Platform, df: pd.DataFrame, target_days: list[date]) -> list[dict]:
    rows = []
    for day in target_days:
        new_revenue = value_by_date(df, "new_fact_without_paid_ua_crm", day - timedelta(days=364)) * GROWTH_FACTOR
        recurrent_revenue = value_by_date(df, "recurrent_fact", day - timedelta(days=365)) * GROWTH_FACTOR
        rows.append(
            {
                "date": day,
                "product": platform.product,
                "new_revenue": new_revenue,
                "recurrent_revenue": recurrent_revenue,
            }
        )
    return rows


def build_web_rows(platform: Platform, df: pd.DataFrame, target_days: list[date], fact_start: date, fact_end: date) -> list[dict]:
    draft_rows = []
    for day in target_days:
        draft_new_revenue = value_by_date(df, "new_fact_without_paid_ua_crm", day - timedelta(days=364)) * GROWTH_FACTOR
        recurrent_revenue = (
            value_by_date(df, "new_fact_without_paid_ua_crm", day - timedelta(days=365)) * WEB_RECURRENT_NEW_FACTOR
            + value_by_date(df, "recurrent_fact", day - timedelta(days=365)) * WEB_RECURRENT_REC_FACTOR
        )
        draft_rows.append(
            {
                "date": day,
                "product": platform.product,
                "draft_new_revenue": draft_new_revenue,
                "recurrent_revenue": recurrent_revenue,
            }
        )

    same_month_fact = sum(
        value_by_date(df, "new_fact_without_paid_ua_crm", day) + value_by_date(df, "recurrent_fact", day)
        for day in pd.date_range(fact_start, fact_end).date
    )
    recurrent_sum = sum(row["recurrent_revenue"] for row in draft_rows)
    draft_new_sum = sum(row["draft_new_revenue"] for row in draft_rows)
    target_new_sum = same_month_fact * GROWTH_FACTOR - recurrent_sum

    rows = []
    for row in draft_rows:
        new_revenue = 0.0 if draft_new_sum == 0 else row["draft_new_revenue"] * target_new_sum / draft_new_sum
        rows.append(
            {
                "date": row["date"],
                "product": row["product"],
                "new_revenue": new_revenue,
                "recurrent_revenue": row["recurrent_revenue"],
            }
        )
    return rows


def build_crm_rows(df: pd.DataFrame, target_days: list[date]) -> list[dict]:
    rows = []
    for day in target_days:
        rows.append(
            {
                "date": day,
                "product": CRM_PRODUCT,
                "new_revenue": value_by_date(df, "crm_fact", day - timedelta(days=365)),
                "recurrent_revenue": 0.0,
            }
        )
    return rows


def fact_sum(df: pd.DataFrame, product: str, fact_days: list[date]) -> float:
    if product == CRM_PRODUCT:
        return sum(value_by_date(df, "crm_fact", day) for day in fact_days)

    return sum(
        value_by_date(df, "new_fact_without_paid_ua_crm", day) + value_by_date(df, "recurrent_fact", day)
        for day in fact_days
    )


def finalize_daily(daily_df: pd.DataFrame, summary_df: pd.DataFrame, days_count: int) -> pd.DataFrame:
    action_by_product = dict(zip(summary_df["product"], summary_df["action"]))
    daily_df = daily_df.copy()
    daily_df["action_revenue"] = daily_df["product"].map(lambda product: action_by_product[product] / days_count)
    daily_df["base_revenue"] = daily_df["new_revenue"] + daily_df["recurrent_revenue"]
    daily_df["revenue"] = daily_df["base_revenue"] + daily_df["action_revenue"]
    return daily_df[["date", "product", "revenue", "new_revenue", "recurrent_revenue", "base_revenue", "action_revenue"]]


def round_numeric_columns(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    numeric_columns = df.select_dtypes(include="number").columns
    df[numeric_columns] = df[numeric_columns].round().astype("int64")
    return df


def build_report(month: date, output_dir: Path) -> tuple[Path, Path]:
    target_start, target_end = month_bounds(month)
    target_days = list(pd.date_range(target_start, target_end).date)
    fact_start = target_start - timedelta(days=365)
    fact_end = target_end - timedelta(days=364)
    same_month_fact_end = target_end - timedelta(days=365)
    fact_days = list(pd.date_range(fact_start, same_month_fact_end).date)

    query_frames = {
        key: run_platform_query(platform, fact_start, fact_end)
        for key, platform in PLATFORMS.items()
    }

    daily_rows = []
    daily_rows.extend(build_mobile_rows(PLATFORMS["ios"], query_frames["ios"], target_days))
    daily_rows.extend(build_mobile_rows(PLATFORMS["android"], query_frames["android"], target_days))
    daily_rows.extend(build_web_rows(PLATFORMS["web"], query_frames["web"], target_days, fact_start, same_month_fact_end))
    daily_rows.extend(build_crm_rows(query_frames["web"], target_days))

    daily_df = pd.DataFrame(daily_rows)

    fact_year = fact_start.year
    fact_column = f"{fact_year} fact"
    summary_rows = []
    for product in [PLATFORMS["ios"].product, PLATFORMS["android"].product, PLATFORMS["web"].product, CRM_PRODUCT]:
        product_rows = daily_df[daily_df["product"] == product]
        source_df = query_frames["web"] if product in {PLATFORMS["web"].product, CRM_PRODUCT} else (
            query_frames["ios"] if product == PLATFORMS["ios"].product else query_frames["android"]
        )
        new = float(product_rows["new_revenue"].sum())
        recurring = float(product_rows["recurrent_revenue"].sum())
        base = new + recurring
        previous_fact = fact_sum(source_df, product, fact_days)
        yoy = base - previous_fact
        summary_rows.append(
            {
                "product": product,
                fact_column: previous_fact,
                "new": new,
                "recurring": recurring,
                "base": base,
                "y-o-y": yoy,
                "y-o-y, %": 0.0 if base == 0 else yoy / base * 100,
                "action": previous_fact * TOTAL_PLAN_FACTOR - base,
                "total plan": previous_fact * TOTAL_PLAN_FACTOR,
            }
        )

    summary_df = pd.DataFrame(summary_rows)

    ug_react_values = summary_df[summary_df["product"].isin(UG_REACT_PRODUCTS)].drop(columns=["product"]).sum(numeric_only=True).to_dict()
    ug_react_values["y-o-y, %"] = (
        0.0 if ug_react_values["base"] == 0 else ug_react_values["y-o-y"] / ug_react_values["base"] * 100
    )

    total_values = summary_df.drop(columns=["product"]).sum(numeric_only=True).to_dict()
    total_values["y-o-y, %"] = 0.0 if total_values["base"] == 0 else total_values["y-o-y"] / total_values["base"] * 100
    summary_df = pd.concat(
        [
            summary_df[summary_df["product"].isin(UG_REACT_PRODUCTS)],
            pd.DataFrame([{"product": "UG React Total", **ug_react_values}]),
            summary_df[summary_df["product"] == CRM_PRODUCT],
            pd.DataFrame([{"product": "Total", **total_values}]),
        ],
        ignore_index=True,
    )

    daily_df = finalize_daily(daily_df, summary_df[~summary_df["product"].isin(["UG React Total", "Total"])], len(target_days))

    output_dir.mkdir(parents=True, exist_ok=True)
    suffix = month.strftime("%Y-%m")
    daily_path = output_dir / f"daily_revenue_plan_{suffix}.csv"
    summary_path = output_dir / f"summary_revenue_plan_{suffix}.csv"

    daily_output = round_numeric_columns(daily_df)
    daily_output["date"] = daily_output["date"].map(lambda day: day.isoformat())
    daily_output.to_csv(daily_path, sep=";", index=False)

    summary_output = summary_df.copy()
    percent = summary_output["y-o-y, %"]
    summary_output = round_numeric_columns(summary_output.drop(columns=["y-o-y, %"]))
    summary_output["y-o-y, %"] = percent.round(6)
    summary_output = summary_output[["product", fact_column, "new", "recurring", "base", "y-o-y", "y-o-y, %", "action", "total plan"]]
    summary_output.to_csv(summary_path, sep=";", index=False)

    return daily_path, summary_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Build daily revenue plan for selected month.")
    parser.add_argument("month", type=parse_month, help="Analyzed month as YYYY-MM-DD, for example 2026-06-01.")
    parser.add_argument("--output-dir", type=Path, default=Path("output"), help="Directory for generated CSV files.")
    args = parser.parse_args()

    daily_path, summary_path = build_report(args.month, args.output_dir)
    print(f"Daily report: {daily_path}")
    print(f"Summary report: {summary_path}")


if __name__ == "__main__":
    main()
