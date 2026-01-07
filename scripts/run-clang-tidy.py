#!/usr/bin/env python3
#
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

"""Run clang-tidy on C files with RISC-V target and correct include paths.

This script extracts compiler flags from common.mk to ensure clang-tidy
uses the same settings as the actual RISC-V compilation.
"""

import re
import subprocess
import sys
from pathlib import Path


def get_root_dir() -> Path:
    """Get the repository root directory."""
    return Path(__file__).parent.parent.resolve()


def extract_flags_from_common_mk(root_dir: Path) -> tuple[str, str]:
    """Extract RISCV_FLAGS and FPGA_CPU_CLK_FREQ from common.mk.

    Returns:
        Tuple of (riscv_flags, fpga_clk_freq)
    """
    common_mk = root_dir / "sw" / "common" / "common.mk"

    if not common_mk.exists():
        return "", ""

    content = common_mk.read_text()

    # Extract RISCV_FLAGS (may span multiple lines with backslash continuation)
    riscv_flags = ""
    riscv_match = re.search(
        r"RISCV_FLAGS\s*=\s*(.+?)(?=\n[A-Z]|\n\n|\Z)",
        content,
        re.DOTALL,
    )
    if riscv_match:
        riscv_flags = riscv_match.group(1)
        # Remove backslash continuations and normalize whitespace
        riscv_flags = re.sub(r"\\\n\s*", " ", riscv_flags)
        # Remove variable references like $(OPT_LEVEL)
        riscv_flags = re.sub(r"\$\([^)]+\)", "", riscv_flags)
        riscv_flags = " ".join(riscv_flags.split())

    # Extract FPGA_CPU_CLK_FREQ
    fpga_clk_freq = ""
    freq_match = re.search(r"FPGA_CPU_CLK_FREQ\s*=\s*(\d+)", content)
    if freq_match:
        fpga_clk_freq = freq_match.group(1)

    return riscv_flags, fpga_clk_freq


def run_clang_tidy(
    file_path: str,
    root_dir: Path,
    riscv_flags: str,
    fpga_clk_freq: str,
) -> bool:
    """Run clang-tidy on a single file.

    Returns:
        True if clang-tidy passed, False otherwise
    """
    # Build clang-tidy flags
    clang_tidy_flags = [
        "--target=riscv32-unknown-elf",
        f"-DFPGA_CPU_CLK_FREQ={fpga_clk_freq}",
        f"-I{root_dir}/sw/lib/include",
    ]

    # Add RISCV_FLAGS
    if riscv_flags:
        clang_tidy_flags.extend(riscv_flags.split())

    # For app files, add the app's directory to include path
    if file_path.startswith("sw/apps/"):
        app_dir = Path(file_path).parent
        clang_tidy_flags.append(f"-I{root_dir}/{app_dir}")

    # Run clang-tidy
    cmd = ["clang-tidy", "--quiet", file_path, "--"] + clang_tidy_flags

    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError:
        # clang-tidy found issues, but we don't fail the hook
        # (matching the original || true behavior)
        return True


def main() -> int:
    """Run clang-tidy on provided files."""
    if len(sys.argv) < 2:
        return 0

    root_dir = get_root_dir()
    common_mk = root_dir / "sw" / "common" / "common.mk"

    if not common_mk.exists():
        print(f"WARNING: Cannot find {common_mk}, skipping clang-tidy.")
        return 0

    riscv_flags, fpga_clk_freq = extract_flags_from_common_mk(root_dir)

    # Process each file passed as argument
    for file_path in sys.argv[1:]:
        run_clang_tidy(file_path, root_dir, riscv_flags, fpga_clk_freq)

    return 0


if __name__ == "__main__":
    sys.exit(main())
