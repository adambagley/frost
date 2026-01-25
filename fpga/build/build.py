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

"""Build FPGA bitstream using Vivado for specified board."""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Board configurations: clock frequency in Hz
BOARD_CONFIG = {
    "x3": {"clock_freq": 322265625},
    "genesys2": {"clock_freq": 133333333},
    "nexys_a7": {"clock_freq": 80000000},
}


def compile_hello_world(project_root: Path, clock_freq: int) -> bool:
    """Compile hello_world application for initial BRAM contents.

    Args:
        project_root: Path to the project root directory
        clock_freq: CPU clock frequency for this board in Hz

    Returns:
        True if compilation succeeded, False otherwise
    """
    app_dir = project_root / "sw" / "apps" / "hello_world"

    if not app_dir.exists():
        print(f"Error: Application directory not found: {app_dir}", file=sys.stderr)
        return False

    # Set up environment
    env = os.environ.copy()
    if "RISCV_PREFIX" not in env:
        env["RISCV_PREFIX"] = "riscv-none-elf-"

    # Set board-specific clock frequency
    env["FPGA_CPU_CLK_FREQ"] = str(clock_freq)

    try:
        print(f"Compiling hello_world with FPGA_CPU_CLK_FREQ={clock_freq}...")

        # Clean first to ensure recompilation with correct settings
        subprocess.run(
            ["make", "clean"],
            cwd=app_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

        # Build with board-specific settings
        result = subprocess.run(
            ["make"],
            cwd=app_dir,
            env=env,
            capture_output=False,  # Show output
            text=True,
            timeout=120,
        )

        if result.returncode != 0:
            return False

        # Verify the output file was created
        sw_mem = app_dir / "sw.mem"
        if not sw_mem.exists():
            print("Error: sw.mem not created for hello_world", file=sys.stderr)
            return False

        return True

    except subprocess.TimeoutExpired:
        print("Error: Compilation timed out for hello_world", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error compiling hello_world: {e}", file=sys.stderr)
        return False


def main() -> None:
    """Build FPGA bitstream for specified board using Vivado.

    Invokes Vivado in batch mode to synthesize, implement, and generate bitstream.
    """
    parser = argparse.ArgumentParser(
        description="Build FPGA bitstream for FROST processor"
    )
    parser.add_argument(
        "board_name", choices=["x3", "genesys2", "nexys_a7"], help="Target board"
    )
    parser.add_argument(
        "--synth-only", action="store_true", help="Stop after synthesis"
    )
    parser.add_argument(
        "--retiming",
        action="store_true",
        help="Enable global retiming during synthesis",
    )
    parser.add_argument(
        "--vivado-path",
        default="vivado",
        help="Path to Vivado executable (default: vivado from PATH)",
    )
    parser.add_argument(
        "--placer-directive",
        default="AltSpreadLogic_high",
        help="Placer directive to use (default: AltSpreadLogic_high)",
    )
    args = parser.parse_args()

    board_name = args.board_name
    script_directory = Path(__file__).parent.resolve()
    project_root = script_directory.parent.parent  # fpga/build -> fpga -> frost root

    # Get board configuration
    board_config = BOARD_CONFIG[board_name]
    clock_freq = board_config["clock_freq"]

    # Compile hello_world for initial BRAM contents with board-specific clock
    print(f"Compiling hello_world for {board_name} ({clock_freq} Hz)...")
    if not compile_hello_world(project_root, clock_freq):
        print("Error: Failed to compile hello_world", file=sys.stderr)
        sys.exit(1)

    # Clean board-specific work directory if it exists (fresh build)
    work_directory = script_directory / board_name / "work"
    if work_directory.exists():
        shutil.rmtree(work_directory)

    # Construct Vivado command line
    vivado_command = [
        args.vivado_path,
        "-mode",
        "batch",  # Non-interactive mode
        "-source",
        str(script_directory / "build.tcl"),
        "-nojournal",  # Don't create journal file
        "-tclargs",
        board_name,
        "1" if args.synth_only else "0",
        "1" if args.retiming else "0",
        "0",  # opt_only (always 0 for regular builds)
        args.placer_directive,
        "",  # checkpoint_path (none - full build)
        "",  # work_suffix (none - use default work directory)
    ]

    # Execute Vivado build (will raise exception on failure)
    subprocess.run(vivado_command, check=True)

    # Extract timing summaries for git tracking
    extract_script = script_directory / "extract_timing_and_util_summary.py"
    subprocess.run(["python3", str(extract_script), board_name], check=True)


if __name__ == "__main__":
    main()
