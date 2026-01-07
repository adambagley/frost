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

"""Docker entrypoint script for FROST development container.

Initializes git submodules if needed before running the command.
"""

import os
import subprocess
import sys
from pathlib import Path

WORKSPACE = Path("/workspace")


def submodules_need_init() -> bool:
    """Check if git submodules need to be initialized."""
    gitmodules = WORKSPACE / ".gitmodules"
    if not gitmodules.exists():
        return False

    # Check if submodules are populated
    freertos_marker = WORKSPACE / "sw" / "FreeRTOS-Kernel" / "include" / "FreeRTOS.h"
    coremark_marker = (
        WORKSPACE / "sw" / "apps" / "coremark" / "coremark" / "core_main.c"
    )

    return not freertos_marker.exists() or not coremark_marker.exists()


def init_submodules() -> None:
    """Initialize git submodules."""
    print("Initializing git submodules...")
    subprocess.run(
        ["git", "-C", str(WORKSPACE), "submodule", "update", "--init", "--recursive"],
        check=True,
    )


def main() -> int:
    """Run entrypoint logic."""
    # Initialize git submodules if needed
    if submodules_need_init():
        init_submodules()

    # Execute the command passed to docker run
    if len(sys.argv) > 1:
        os.execvp(sys.argv[1], sys.argv[1:])

    return 0


if __name__ == "__main__":
    sys.exit(main())
