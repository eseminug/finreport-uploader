from __future__ import annotations

from datetime import date
from pathlib import Path

import pandas as pd
import streamlit as st

from main import build_report, upload_financial_plan


OUTPUT_DIR = Path("output")


def first_day(day: date) -> date:
    return day.replace(day=1)


def report_paths(month: date) -> tuple[Path, Path]:
    suffix = month.strftime("%Y-%m")
    return OUTPUT_DIR / f"daily_revenue_plan_{suffix}.csv", OUTPUT_DIR / f"summary_revenue_plan_{suffix}.csv"


def read_report(path: Path) -> pd.DataFrame:
    return pd.read_csv(path, sep=";")


def money_format(value) -> str:
    if pd.isna(value):
        return ""
    return f"${float(value):,.0f}"


def percent_format(value) -> str:
    if pd.isna(value):
        return ""
    return f"{float(value):,.2f}%"


def style_total_rows(row: pd.Series) -> list[str]:
    product = row.get("product", "")
    if product == "UG React Total":
        return ["font-weight: 700; background-color: #eef5ff; padding-left: 24px;" for _ in row]
    if product == "Total":
        return ["font-weight: 700; background-color: #edf7ed; padding-left: 24px;" for _ in row]
    return ["" for _ in row]


def formatted_report(df: pd.DataFrame):
    money_columns = [column for column in df.columns if column not in {"date", "product", "y-o-y, %"}]
    formatter = {column: money_format for column in money_columns}
    if "y-o-y, %" in df.columns:
        formatter["y-o-y, %"] = percent_format

    styler = df.style.format(formatter)
    if "product" in df.columns:
        styler = styler.apply(style_total_rows, axis=1)
    return styler


def show_report(path: Path, title: str) -> None:
    st.subheader(title)
    if path.exists():
        st.dataframe(formatted_report(read_report(path)), use_container_width=True, hide_index=True)
    else:
        st.info("Not calculated yet.")


def render_app() -> None:
    st.set_page_config(page_title="Financial Plan Uploader", layout="wide")
    st.title("Financial Plan Uploader")

    selected_date = st.date_input("Month", value=first_day(date.today()), format="YYYY-MM-DD")
    selected_month = first_day(selected_date)
    daily_path, summary_path = report_paths(selected_month)

    if st.button("Calculate Plan", type="primary", use_container_width=True):
        with st.spinner(f"Calculating {selected_month:%Y-%m}..."):
            daily_path, summary_path = build_report(selected_month, OUTPUT_DIR)
        st.session_state["last_calculation_message"] = f"Calculated: {daily_path.name} and {summary_path.name}"
        st.rerun()

    if "last_calculation_message" in st.session_state:
        st.success(st.session_state.pop("last_calculation_message"))

    upload = st.button("Upload Plan", disabled=not daily_path.exists(), use_container_width=True)
    if upload:
        with st.spinner(f"Uploading {daily_path.name}..."):
            message = upload_financial_plan(daily_path)
        if "ошиб" in message.lower() or "error" in message.lower():
            st.error(message)
        else:
            st.success(message or "Upload completed.")

    tab_daily, tab_summary = st.tabs(["Daily Plan", "Summary"])
    with tab_daily:
        show_report(daily_path, daily_path.name)
    with tab_summary:
        show_report(summary_path, summary_path.name)


if __name__ == "__main__":
    render_app()
