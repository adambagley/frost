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

"""Program FPGA bitstream to specified board (x3, genesys2, or nexys_a7)."""

import argparse
import subprocess
from pathlib import Path


def main() -> None:
    """Program FPGA bitstream to specified board via JTAG.

    Loads compiled bitstream into FPGA configuration memory, replacing current design.
    """
    parser = argparse.ArgumentParser(
        description="Program FPGA bitstream to specified board via JTAG"
    )
    parser.add_argument(
        "board",
        choices=["x3", "genesys2", "nexys_a7"],
        help="Target board",
    )
    parser.add_argument(
        "remote_host",
        nargs="?",
        default="",
        help="Remote server hostname or IP (port 3121 will be used)",
    )
    parser.add_argument(
        "--vivado-path",
        default="vivado",
        help="Path to Vivado executable (default: vivado from PATH)",
    )
    args = parser.parse_args()

    # Compute absolute paths based on script location
    script_dir = Path(__file__).parent.resolve()
    project_root = (
        script_dir.parent.parent
    )  # fpga/program_bitstream -> fpga -> frost root
    tcl_script = script_dir / "program_bitstream.tcl"

    # Construct Vivado command to program bitstream
    # Note: -nojournal and -nolog must come BEFORE -tclargs, otherwise they get
    # passed to the TCL script as arguments instead of being interpreted by Vivado
    vivado_command = [
        args.vivado_path,
        "-mode",
        "batch",  # Non-interactive mode
        "-nojournal",
        "-nolog",
        "-source",
        str(tcl_script),
        "-tclargs",
        str(project_root),  # Pass project root as first arg
        args.board,
    ]

    if args.remote_host:
        vivado_command.append(args.remote_host)

    # Execute Vivado command (will raise exception on failure)
    subprocess.run(vivado_command, check=True)


if __name__ == "__main__":
    main()
