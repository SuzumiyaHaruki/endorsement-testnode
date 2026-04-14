#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt


def load_summary_dir(input_dir: Path) -> pd.DataFrame:
    rows = []
    for f in sorted(input_dir.glob("*/summary.json")):
        try:
            obj = json.loads(f.read_text(encoding="utf-8"))
            obj["_case_dir"] = f.parent.name
            rows.append(obj)
        except Exception as e:
            print(f"[WARN] failed to read {f}: {e}")

    if not rows:
        raise RuntimeError(f"no summary.json found under {input_dir}")

    df = pd.DataFrame(rows)

    numeric_cols = [
        "tx_total",
        "tx_receipt_count",
        "tx_error_count",
        "tx_timeout_count",
        "tx_send_error_count",
        "tx_receipt_error_count",
        "lat_avg_ms",
        "lat_p50_ms",
        "lat_p95_ms",
        "lat_p99_ms",
        "keep_total",
        "keep_success",
        "keep_retention_rate",
        "fail_total",
        "fail_success",
        "fail_drop_rate",
        "disabled_skip",
        "endorsement_satisfied",
        "endorsement_failed",
        "rebuild_count",
        "remote_request_count",
        "verify_ok_count",
        "case_log_lines",
    ]
    for c in numeric_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    if "case_name" not in df.columns:
        df["case_name"] = df["_case_dir"]

    return df


def ensure_output_dir(out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)


def save_df(df: pd.DataFrame, out_path: Path):
    df.to_csv(out_path, index=False, encoding="utf-8")
    print(f"[OK] wrote {out_path}")


def plot_bar(
    labels,
    values,
    title,
    ylabel,
    out_file: Path,
    ylim=None,
    rotation=20,
):
    plt.figure(figsize=(9, 5))
    plt.bar(labels, values)
    plt.title(title)
    plt.ylabel(ylabel)
    plt.xticks(rotation=rotation, ha="right")
    if ylim is not None:
        plt.ylim(*ylim)
    plt.tight_layout()
    plt.savefig(out_file, dpi=300)
    plt.close()
    print(f"[OK] wrote {out_file}")


def plot_grouped_bar(
    labels,
    series,
    title,
    ylabel,
    out_file: Path,
    ylim=None,
    rotation=20,
):
    n = len(labels)
    m = len(series)
    width = 0.8 / max(m, 1)
    x = list(range(n))

    plt.figure(figsize=(10, 5))
    for i, (name, values) in enumerate(series):
        offsets = [xi - 0.4 + width / 2 + i * width for xi in x]
        plt.bar(offsets, values, width=width, label=name)

    plt.title(title)
    plt.ylabel(ylabel)
    plt.xticks(x, labels, rotation=rotation, ha="right")
    if ylim is not None:
        plt.ylim(*ylim)
    if m > 1:
        plt.legend()
    plt.tight_layout()
    plt.savefig(out_file, dpi=300)
    plt.close()
    print(f"[OK] wrote {out_file}")


# ---------------- correctness ----------------

def plot_correctness(df: pd.DataFrame, out_dir: Path):
    ensure_output_dir(out_dir)
    save_df(df, out_dir / "summary_correctness.csv")

    order = [
        "correct_single_keep",
        "correct_single_fail",
        "correct_1keep_1fail",
        "correct_2keep_1fail",
        "correct_2fail_1keep",
    ]
    label_map = {
        "correct_single_keep": "single keep",
        "correct_single_fail": "single fail",
        "correct_1keep_1fail": "1 keep + 1 fail",
        "correct_2keep_1fail": "2 keep + 1 fail",
        "correct_2fail_1keep": "2 fail + 1 keep",
    }

    d = df[df["case_name"].isin(order)].copy()
    d["case_name"] = pd.Categorical(d["case_name"], categories=order, ordered=True)
    d = d.sort_values("case_name")

    labels = [label_map[x] for x in d["case_name"]]

    plot_grouped_bar(
        labels=labels,
        series=[
            ("submitted receipts", d["tx_receipt_count"].fillna(0).tolist()),
            ("keep success", d["keep_success"].fillna(0).tolist()),
            ("fail success", d["fail_success"].fillna(0).tolist()),
        ],
        title="Correctness scenarios: submitted transaction outcomes",
        ylabel="Transaction count",
        out_file=out_dir / "fig_correctness_success.png",
    )

    plot_grouped_bar(
        labels=labels,
        series=[
            ("keep retention", d["keep_retention_rate"].fillna(0).tolist()),
            ("fail drop", d["fail_drop_rate"].fillna(0).tolist()),
        ],
        title="Correctness scenarios: keep retention and fail drop",
        ylabel="Rate",
        out_file=out_dir / "fig_correctness_rates.png",
        ylim=(0, 1.05),
    )


# ---------------- performance ----------------

def plot_performance(df: pd.DataFrame, out_dir: Path):
    ensure_output_dir(out_dir)
    save_df(df, out_dir / "summary_performance.csv")

    keep_order = [
        "perf_baseline_keep_only",
        "perf_local_keep_only",
        "perf_remote_keep_only",
    ]
    keep_label_map = {
        "perf_baseline_keep_only": "baseline",
        "perf_local_keep_only": "local",
        "perf_remote_keep_only": "remote",
    }

    keep_df = df[df["case_name"].isin(keep_order)].copy()
    keep_df["case_name"] = pd.Categorical(keep_df["case_name"], categories=keep_order, ordered=True)
    keep_df = keep_df.sort_values("case_name")
    keep_labels = [keep_label_map[x] for x in keep_df["case_name"]]

    plot_grouped_bar(
        labels=keep_labels,
        series=[
            ("average latency", keep_df["lat_avg_ms"].fillna(0).tolist()),
            ("P95 latency", keep_df["lat_p95_ms"].fillna(0).tolist()),
        ],
        title="Keep-only workload: baseline vs local vs remote",
        ylabel="Latency (ms)",
        out_file=out_dir / "fig_performance_keep_only_latency.png",
    )

    mixed_order = [
        "perf_remote_mixed_10pct_fail",
        "perf_remote_mixed_30pct_fail",
    ]
    mixed_label_map = {
        "perf_remote_mixed_10pct_fail": "10% fail",
        "perf_remote_mixed_30pct_fail": "30% fail",
    }

    mixed_df = df[df["case_name"].isin(mixed_order)].copy()
    mixed_df["case_name"] = pd.Categorical(mixed_df["case_name"], categories=mixed_order, ordered=True)
    mixed_df = mixed_df.sort_values("case_name")
    mixed_labels = [mixed_label_map[x] for x in mixed_df["case_name"]]

    plot_grouped_bar(
        labels=mixed_labels,
        series=[
            ("keep retention", mixed_df["keep_retention_rate"].fillna(0).tolist()),
            ("fail drop", mixed_df["fail_drop_rate"].fillna(0).tolist()),
        ],
        title="Remote mixed workload correctness",
        ylabel="Rate",
        out_file=out_dir / "fig_performance_mixed_correctness.png",
        ylim=(0, 1.05),
    )

    plot_grouped_bar(
        labels=mixed_labels,
        series=[
            ("average latency", mixed_df["lat_avg_ms"].fillna(0).tolist()),
            ("P95 latency", mixed_df["lat_p95_ms"].fillna(0).tolist()),
        ],
        title="Remote mixed workload latency",
        ylabel="Latency (ms)",
        out_file=out_dir / "fig_performance_mixed_latency.png",
    )


# ---------------- threshold ----------------

def plot_threshold(df: pd.DataFrame, out_dir: Path):
    ensure_output_dir(out_dir)
    save_df(df, out_dir / "summary_threshold.csv")

    order = [
        "threshold_2of3_fail20",
        "threshold_3of3_fail20",
        "threshold_2of3_fail40",
        "threshold_3of3_fail40",
    ]
    label_map = {
        "threshold_2of3_fail20": "2-of-3 / 20%",
        "threshold_3of3_fail20": "3-of-3 / 20%",
        "threshold_2of3_fail40": "2-of-3 / 40%",
        "threshold_3of3_fail40": "3-of-3 / 40%",
    }

    d = df[df["case_name"].isin(order)].copy()
    d["case_name"] = pd.Categorical(d["case_name"], categories=order, ordered=True)
    d = d.sort_values("case_name")
    labels = [label_map[x] for x in d["case_name"]]

    plot_grouped_bar(
        labels=labels,
        series=[
            ("average latency", d["lat_avg_ms"].fillna(0).tolist()),
            ("P95 latency", d["lat_p95_ms"].fillna(0).tolist()),
        ],
        title="Threshold impact on latency",
        ylabel="Latency (ms)",
        out_file=out_dir / "fig_threshold_latency.png",
    )

    plot_grouped_bar(
        labels=labels,
        series=[
            ("keep retention", d["keep_retention_rate"].fillna(0).tolist()),
            ("fail drop", d["fail_drop_rate"].fillna(0).tolist()),
        ],
        title="Threshold impact on correctness",
        ylabel="Rate",
        out_file=out_dir / "fig_threshold_correctness.png",
        ylim=(0, 1.05),
    )

    if "rebuild_count" in d.columns:
        plot_bar(
            labels=labels,
            values=d["rebuild_count"].fillna(0).tolist(),
            title="Threshold impact on rebuild count",
            ylabel="Rebuild count",
            out_file=out_dir / "fig_threshold_rebuild.png",
        )


# ---------------- fault ----------------

def plot_fault(df: pd.DataFrame, out_dir: Path):
    ensure_output_dir(out_dir)
    save_df(df, out_dir / "summary_fault.csv")

    order = [
        "fault_remote_normal",
        "fault_delay_100ms",
        "fault_delay_300ms",
        "fault_delay_500ms",
        "fault_down_1",
        "fault_down_2",
    ]
    label_map = {
        "fault_remote_normal": "normal",
        "fault_delay_100ms": "delay 100ms",
        "fault_delay_300ms": "delay 300ms",
        "fault_delay_500ms": "delay 500ms",
        "fault_down_1": "1 node down",
        "fault_down_2": "2 nodes down",
    }

    d = df[df["case_name"].isin(order)].copy()
    d["case_name"] = pd.Categorical(d["case_name"], categories=order, ordered=True)
    d = d.sort_values("case_name")
    labels = [label_map[x] for x in d["case_name"]]

    # 只保留 fault_status=applied 或 noop 的结果，避免注入失败点混进正式图
    if "fault_status" in d.columns:
        d_valid = d[d["fault_status"].fillna("").isin(["applied", "noop"])].copy()
        labels_valid = [label_map[x] for x in d_valid["case_name"]]
    else:
        d_valid = d
        labels_valid = labels

    plot_grouped_bar(
        labels=labels_valid,
        series=[
            ("average latency", d_valid["lat_avg_ms"].fillna(0).tolist()),
            ("P95 latency", d_valid["lat_p95_ms"].fillna(0).tolist()),
        ],
        title="Fault impact on latency",
        ylabel="Latency (ms)",
        out_file=out_dir / "fig_fault_latency.png",
    )

    plot_grouped_bar(
        labels=labels_valid,
        series=[
            ("keep retention", d_valid["keep_retention_rate"].fillna(0).tolist()),
            ("fail drop", d_valid["fail_drop_rate"].fillna(0).tolist()),
        ],
        title="Fault impact on correctness",
        ylabel="Rate",
        out_file=out_dir / "fig_fault_correctness.png",
        ylim=(0, 1.05),
    )

    if "rebuild_count" in d_valid.columns:
        plot_bar(
            labels=labels_valid,
            values=d_valid["rebuild_count"].fillna(0).tolist(),
            title="Fault impact on rebuild count",
            ylabel="Rebuild count",
            out_file=out_dir / "fig_fault_rebuild.png",
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--category", required=True, choices=["correctness", "performance", "threshold", "fault"])
    parser.add_argument("--input", required=True, help="Experiment output dir, e.g. ./exp_fault")
    parser.add_argument("--output", required=True, help="Output figure dir")
    args = parser.parse_args()

    input_dir = Path(args.input)
    output_dir = Path(args.output)

    df = load_summary_dir(input_dir)

    if args.category == "correctness":
        plot_correctness(df, output_dir)
    elif args.category == "performance":
        plot_performance(df, output_dir)
    elif args.category == "threshold":
        plot_threshold(df, output_dir)
    elif args.category == "fault":
        plot_fault(df, output_dir)

    print(f"[OK] done: {args.category}")


if __name__ == "__main__":
    main()