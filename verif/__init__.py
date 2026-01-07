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

"""Frost RISC-V CPU Verification Framework.

This package provides a comprehensive verification environment for the Frost
RISC-V CPU using CoCoTB (Coroutine-based Co-simulation Testbench).

Package Structure
-----------------

Subpackages:
    encoders
        RISC-V instruction encoding utilities for all supported extensions
        (RV32IMABCF + Zicsr, Zicntr, Zba, Zbb, Zbs, Zbkb, Zicond)

    models
        Software reference models for ALU operations, memory, and branch logic

    monitors
        Runtime verification monitors for register file, PC, and memory

    tests
        Test cases and infrastructure for random and directed testing

    utils
        Utility functions for data conversion, logging, and validation

Modules:
    config
        Central configuration constants (bit masks, pipeline parameters, etc.)

    verification_types
        Type aliases for type safety (Address, RegisterIndex, etc.)

    exceptions
        Custom exception hierarchy for verification failures

Quick Start
-----------
Run the default random instruction test::

    make test TEST=test_random_riscv_regression

Run directed tests::

    make test TEST=test_directed_lr_sc
    make test TEST=test_directed_trap_handling

Run integration tests with real programs::

    make test TEST=test_real_program

For more information, see the README.md in this directory.
"""

# Re-export commonly used types for convenience
from verification_types import Address, RegisterIndex, Instruction
from config import MASK32, PIPELINE_DEPTH

__all__ = [
    "Address",
    "RegisterIndex",
    "Instruction",
    "MASK32",
    "PIPELINE_DEPTH",
]
