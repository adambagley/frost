#!/usr/bin/env python3

#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Extract key timing and utilization metrics from Vivado reports.

Creates a sanitized summary file suitable for git tracking, without
machine-specific paths or hostnames.
"""

import re
import sys
from pathlib import Path
from typing import Any


def extract_timing_summary(timing_rpt: str) -> dict[str, Any]:
    """Extract WNS, TNS, WHS, THS from timing report."""
    result: dict[str, Any] = {}

    # Find the Design Timing Summary table
    # Format: WNS(ns) TNS(ns) TNS Failing Endpoints ...
    pattern = r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+\s*-+.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)"
    match = re.search(pattern, timing_rpt)
    if match:
        result["wns_ns"] = float(match.group(1))
        result["tns_ns"] = float(match.group(2))
        result["tns_failing_endpoints"] = int(match.group(3))
        result["tns_total_endpoints"] = int(match.group(4))
        result["whs_ns"] = float(match.group(5))
        result["ths_ns"] = float(match.group(6))
        result["ths_failing_endpoints"] = int(match.group(7))
        result["ths_total_endpoints"] = int(match.group(8))

    # Check if timing is met
    if "All user specified timing constraints are met" in timing_rpt:
        result["timing_met"] = True
    else:
        result["timing_met"] = False

    return result


def extract_clock_info(timing_rpt: str) -> dict[str, Any]:
    """Extract clock frequencies from timing report."""
    clocks: dict[str, Any] = {}

    # Find clock_from_mmcm period
    match = re.search(
        r"clock_from_mmcm\s+\{[\d. ]+\}\s+([\d.]+)\s+([\d.]+)", timing_rpt
    )
    if match:
        clocks["main_clock_period_ns"] = float(match.group(1))
        clocks["main_clock_freq_mhz"] = float(match.group(2))

    return clocks


def extract_worst_path(timing_rpt: str) -> dict[str, Any]:
    """Extract worst path details from timing report."""
    result: dict[str, Any] = {}

    # Find the clock_from_mmcm section (main clock, not debug)
    # Match both MET and VIOLATED slack - we want the worst path regardless
    mmcm_section = re.search(
        r"From Clock:\s+clock_from_mmcm\s*\n\s*To Clock:\s+clock_from_mmcm.*?"
        r"Max Delay Paths\s*\n-+\s*\n"
        r"Slack \((?:MET|VIOLATED)\) :\s+([-\d.]+)ns.*?"
        r"Source:\s+(\S+).*?"
        r"Destination:\s+(\S+).*?"
        r"Data Path Delay:\s+([\d.]+)ns\s+\(logic ([\d.]+)ns.*?route ([\d.]+)ns.*?"
        r"Logic Levels:\s+(\d+)",
        timing_rpt,
        re.DOTALL,
    )

    if mmcm_section:
        result["slack_ns"] = float(mmcm_section.group(1))
        result["source"] = mmcm_section.group(2)
        result["destination"] = mmcm_section.group(3)
        result["data_path_delay_ns"] = float(mmcm_section.group(4))
        result["logic_delay_ns"] = float(mmcm_section.group(5))
        result["route_delay_ns"] = float(mmcm_section.group(6))
        result["logic_levels"] = int(mmcm_section.group(7))

    return result


def extract_utilization(util_rpt: str) -> dict[str, Any]:
    """Extract resource utilization from utilization report."""
    result: dict[str, Any] = {}

    # Table format: | Site Type | Used | Fixed | Prohibited | Available | Util% |
    # CLB LUTs (UltraScale+) or Slice LUTs (7-series)
    match = re.search(
        r"\|\s*(?:CLB|Slice) LUTs\*?\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)",
        util_rpt,
    )
    if match:
        result["luts_used"] = int(match.group(1))
        result["luts_available"] = int(match.group(2))
        percent_str = match.group(3).replace("<", "")
        result["luts_percent"] = float(percent_str)

    # CLB Registers (UltraScale+) or Slice Registers (7-series)
    match = re.search(
        r"\|\s*(?:CLB|Slice) Registers\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)",
        util_rpt,
    )
    if match:
        result["registers_used"] = int(match.group(1))
        result["registers_available"] = int(match.group(2))
        percent_str = match.group(3).replace("<", "")
        result["registers_percent"] = float(percent_str)

    # Block RAM
    match = re.search(
        r"\|\s*Block RAM Tile\s*\|\s*([\d.]+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)",
        util_rpt,
    )
    if match:
        result["bram_used"] = float(match.group(1))
        result["bram_available"] = int(match.group(2))
        percent_str = match.group(3).replace("<", "")
        result["bram_percent"] = float(percent_str)

    # DSPs
    match = re.search(
        r"\|\s*DSPs\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([\d.<]+)",
        util_rpt,
    )
    if match:
        result["dsps_used"] = int(match.group(1))
        result["dsps_available"] = int(match.group(2))
        percent_str = match.group(3).replace("<", "")
        result["dsps_percent"] = float(percent_str)

    return result


def fmt(value: Any, fmt_spec: str = ".3f") -> str:
    """Format a value with the given format spec, or return 'N/A' if missing."""
    if value is None or value == "N/A":
        return "N/A"
    return f"{value:{fmt_spec}}"


def format_summary(
    board: str, timing: dict, clocks: dict, worst_path: dict, util: dict
) -> str:
    """Format the extracted data as a markdown summary."""
    lines = [
        f"# FROST FPGA Build Summary: {board}",
        "",
        "## Timing",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Clock Frequency | {fmt(clocks.get('main_clock_freq_mhz'))} MHz |",
        f"| Clock Period | {fmt(clocks.get('main_clock_period_ns'))} ns |",
        f"| WNS (Setup) | {fmt(timing.get('wns_ns'))} ns |",
        f"| TNS (Setup) | {fmt(timing.get('tns_ns'))} ns ({timing.get('tns_failing_endpoints', 'N/A')} failing) |",
        f"| WHS (Hold) | {fmt(timing.get('whs_ns'))} ns |",
        f"| THS (Hold) | {fmt(timing.get('ths_ns'))} ns ({timing.get('ths_failing_endpoints', 'N/A')} failing) |",
        f"| Timing Met | {'Yes' if timing.get('timing_met') else 'No'} |",
        "",
        "## Worst Setup Path",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Slack | {fmt(worst_path.get('slack_ns'))} ns |",
        f"| Data Path Delay | {fmt(worst_path.get('data_path_delay_ns'))} ns |",
        f"| Logic Delay | {fmt(worst_path.get('logic_delay_ns'))} ns |",
        f"| Route Delay | {fmt(worst_path.get('route_delay_ns'))} ns |",
        f"| Logic Levels | {worst_path.get('logic_levels', 'N/A')} |",
        "",
        "### Path Endpoints",
        "",
        f"- **Source**: `{worst_path.get('source', 'N/A')}`",
        f"- **Destination**: `{worst_path.get('destination', 'N/A')}`",
        "",
        "## Resource Utilization",
        "",
        "| Resource | Used | Available | Util% |",
        "|----------|------|-----------|-------|",
        f"| LUTs | {util.get('luts_used', 'N/A')} | {util.get('luts_available', 'N/A')} | {fmt(util.get('luts_percent'), '.2f')}% |",
        f"| Registers | {util.get('registers_used', 'N/A')} | {util.get('registers_available', 'N/A')} | {fmt(util.get('registers_percent'), '.2f')}% |",
        f"| Block RAM | {util.get('bram_used', 'N/A')} | {util.get('bram_available', 'N/A')} | {fmt(util.get('bram_percent'), '.2f')}% |",
        f"| DSPs | {util.get('dsps_used', 'N/A')} | {util.get('dsps_available', 'N/A')} | {fmt(util.get('dsps_percent'), '.2f')}% |",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    """Extract timing and utilization summaries from Vivado reports."""
    if len(sys.argv) < 2:
        print("Usage: extract_timing_and_util_summary.py <board>")
        print("  board: x3, genesys2, or nexys_a7")
        sys.exit(1)

    board = sys.argv[1]
    if board not in ["x3", "genesys2", "nexys_a7"]:
        print(
            f"Error: Invalid board '{board}'. Must be 'x3', 'genesys2', or 'nexys_a7'"
        )
        sys.exit(1)

    script_dir = Path(__file__).parent.resolve()
    board_dir = script_dir / board
    work_dir = board_dir / "work"

    # Process all available build stages
    stages = ["post_synth", "post_opt", "post_place", "post_route"]

    summaries_written = 0
    for stage in stages:
        timing_rpt_path = work_dir / f"{stage}_timing.rpt"
        util_rpt_path = work_dir / f"{stage}_util.rpt"

        if not timing_rpt_path.exists() or not util_rpt_path.exists():
            continue

        timing_rpt = timing_rpt_path.read_text()
        util_rpt = util_rpt_path.read_text()

        timing = extract_timing_summary(timing_rpt)
        clocks = extract_clock_info(timing_rpt)
        worst_path = extract_worst_path(timing_rpt)
        util = extract_utilization(util_rpt)

        # Write combined summary to board_dir (tracked in git)
        summary = format_summary(f"{board} ({stage})", timing, clocks, worst_path, util)
        summary_path = board_dir / f"SUMMARY_{stage}.md"
        summary_path.write_text(summary)

        print(f"Summary written to: {summary_path}")
        summaries_written += 1

    if summaries_written == 0:
        print("Error: No timing/utilization reports found")
        sys.exit(1)

    print(f"\nWrote {summaries_written} summary file(s)")


if __name__ == "__main__":
    main()
