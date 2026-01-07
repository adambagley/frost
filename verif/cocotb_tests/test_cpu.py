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

"""Random instruction verification test for RISC-V CPU core.

Test RISC-V CPU - Random Regression
===================================

This module implements the main random instruction testbench for the Frost
RISC-V CPU. It uses constrained-random testing to verify CPU correctness
by generating thousands of random valid instructions and comparing hardware
execution against a software reference model.

Test Approach:
    1. Generate random RISC-V instruction
    2. Encode to binary and drive into DUT
    3. Model expected behavior in software
    4. Hardware monitors verify outputs match expectations
    5. Repeat thousands of times with coverage tracking

What This Tests:
    - All supported RISC-V instructions (100+ types across I, M, A, B-subset, Zicsr)
    - Register file reads and writes
    - Program counter updates (sequential, branch, jump)
    - Memory loads and stores (byte, halfword, word)
    - Pipeline behavior (stalls, flushes, hazards)
    - Branch prediction and misprediction handling

What This Does NOT Test:
    - Instruction fetch (instructions driven directly from testbench)
    - Instruction cache behavior
    - Data cache behavior
    - Multi-cycle memory latency
    (See test_real_program.py for full system integration tests)

Related Test Modules:
    - test_directed_atomics.py: LR.W/SC.W atomic instruction tests
    - test_directed_traps.py: ECALL, EBREAK, MRET, interrupt handling
    - test_compressed.py: C extension compressed instruction tests
    - test_real_program.py: Full system integration tests

Entry Points:
    - test_random_riscv_regression(): Default random test (16,000 instructions)
    - test_random_riscv_regression_force_one_address(): Single address stress test
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from monitors.monitors import regfile_monitor, pc_monitor
from config import (
    MASK32,
    PIPELINE_DEPTH,
)
from encoders.op_tables import R_ALU, LOADS, STORES, BRANCHES, JUMPS
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface, TestStatistics
from cocotb_tests.instruction_generator import InstructionGenerator
from cocotb_tests.cpu_model import CPUModel
from cocotb_tests.test_state import TestState
from cocotb_tests.test_common import (
    TestConfig,
    handle_branch_flush,
    flush_remaining_outputs,
)
from utils.instruction_logger import InstructionLogger


# ============================================================================
# Main Random Regression Test
# ============================================================================


async def test_random_riscv_regression_main(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Main coroutine for random RISC-V regression: ALU + branches + jumps + loads/stores.

    Test Flow:
        1. Initialize DUT and start clock
        2. Start concurrent monitors for register file, PC, and memory
        3. Reset DUT
        4. Execute main loop:
            a. Generate random instruction (or NOP if branch flush)
            b. Encode instruction to binary
            c. Model expected behavior in software
            d. Drive instruction into DUT
            e. Queue expected results for monitors to check
            f. Update software state for next cycle
        5. Flush remaining pipeline outputs
        6. Verify coverage

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
    """
    if config is None:
        config = TestConfig()
    # ========================================================================
    # Initialization Phase
    # ========================================================================

    # Create interfaces and statistics tracker
    dut_if = DUTInterface(dut)
    stats = TestStatistics()
    operation = "addi"
    state = TestState()

    # Initialize DUT signals and register file with random values
    # IMPORTANT: Drive a 32-bit NOP (addi x0,x0,0) instead of 0 during initialization.
    # With C extension, 0 looks like a compressed instruction (bits [1:0] = 00).
    nop_32bit = 0x00000013  # addi x0, x0, 0
    dut_if.instruction = nop_32bit
    state.register_file_current = dut_if.initialize_registers()

    # Start free-running clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Start concurrent monitors (run in background, checking outputs as they arrive)
    cocotb.start_soon(regfile_monitor(dut, state.register_file_current_expected_queue))
    cocotb.start_soon(pc_monitor(dut, state.program_counter_expected_values_queue))

    # Reset DUT and wait for reset completion
    # Returns cycle count for CSR counter synchronization
    # Note: RTL cycle counter is held at 0 during reset, so subtract reset cycles
    reset_cycle_count = await dut_if.reset_dut(config.reset_cycles)
    state.csr_cycle_counter = reset_cycle_count - config.reset_cycles

    # Initialize memory model and start memory interface monitor
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file state for first instruction.
    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup: Fill pipeline with NOPs to synchronize expected value queues
    # ========================================================================
    # With 6-stage pipeline, we need to queue expected values for the first
    # PIPELINE_DEPTH cycles before o_vld starts firing. Drive NOPs to ensure
    # predictable initial state.
    cocotb.log.info(f"=== Warming up pipeline ({PIPELINE_DEPTH} NOPs) ===")
    nop_32bit = 0x00000013  # addi x0, x0, 0
    for warmup_cycle in range(PIPELINE_DEPTH):
        # Queue expected outputs for NOP (no register change, sequential PC)
        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        expected_pc = (state.program_counter_current + 4) & MASK32
        state.program_counter_expected_values_queue.append(expected_pc)

        # Drive NOP
        dut_if.instruction = nop_32bit

        # Wait for clock edge
        await RisingEdge(dut_if.clock)
        state.increment_cycle_counter()
        state.increment_instret_counter()

        # Update PC for next iteration
        state.update_program_counter(expected_pc)
        state.advance_register_state()

        cocotb.log.info(
            f"Warmup NOP {warmup_cycle}: pc_cur={state.program_counter_current}"
        )

    # ========================================================================
    # Main Test Loop - Random Instruction Generation and Verification
    # ========================================================================

    for cycle in range(config.num_loops):
        stats.cycles_executed += 1

        # Wait for DUT to be ready (not stalled, not in reset)
        if cycle != 0:
            await FallingEdge(dut_if.clock)
        wait_cycles = await dut_if.wait_ready()
        state.csr_cycle_counter += wait_cycles  # Track cycles spent waiting for stalls

        # ====================================================================
        # Step 1: Generate Instruction
        # ====================================================================
        # After a taken branch/jump, flush pipeline with NOP to model speculative
        # execution behavior. Otherwise, generate a new random instruction.
        # All control flow (JAL, JALR, branches) resolved in EX stage, need 3 flush cycles.
        if state.is_in_flush:
            operation, rd, rs1, rs2, imm = handle_branch_flush(state, operation)
            offset = None
            if config.use_structured_logging:
                InstructionLogger.log_branch_flush(cycle, state.program_counter_current)
        else:
            # Generate random instruction with optional memory address constraints
            mem_constraint = (
                config.memory_init_size
                if config.constrain_addresses_to_memory
                else None
            )
            instr_params = InstructionGenerator.generate_random_instruction(
                state.register_file_previous, config.force_one_address, mem_constraint
            )
            operation = instr_params.operation
            rd = instr_params.destination_register
            rs1 = instr_params.source_register_1
            rs2 = instr_params.source_register_2
            imm = instr_params.immediate
            offset = instr_params.branch_offset

        # Extract CSR address for CSR instructions (None during branch flushes)
        csr_address = None
        if not state.is_in_flush:
            csr_address = instr_params.csr_address

        # Record instruction execution for coverage tracking
        stats.record_instruction(
            operation, state.branch_taken_current if operation in BRANCHES else None
        )

        # ====================================================================
        # Step 2: Encode Instruction to Binary
        # ====================================================================
        instr = InstructionGenerator.encode_instruction(
            operation, rd, rs1, rs2, imm, offset, csr_address
        )

        # ====================================================================
        # Step 3: Model Expected Behavior in Software
        # ====================================================================
        # Compute what the hardware SHOULD produce for this instruction
        rd_to_update, rd_wb_value, expected_pc = CPUModel.model_instruction_execution(
            state, mem_model, operation, rd, rs1, rs2, imm, offset, csr_address
        )

        # For store instructions, model the expected memory write
        CPUModel.model_memory_write(state, mem_model, operation, rs1, rs2, imm)

        # ====================================================================
        # Step 4: Update Software State
        # ====================================================================
        # Update register file model if instruction writes to a register
        if rd_to_update:
            state.register_file_current[rd_to_update] = rd_wb_value & MASK32

        # Queue expected results for monitors to verify when they emerge from pipeline
        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        state.program_counter_expected_values_queue.append(expected_pc)

        # ====================================================================
        # Step 5: Drive Instruction into DUT
        # ====================================================================
        dut_if.instruction = instr

        # Log instruction execution (optional structured format for debugging)
        if config.use_structured_logging:
            addr = (state.register_file_previous[rs1] + imm) & MASK32
            InstructionLogger.log_instruction_execution(
                cycle=cycle,
                operation=operation,
                pc_current=state.program_counter_current,
                pc_expected=expected_pc,
                destination_register=rd_to_update,
                writeback_value=rd_wb_value,
                source_register_1=rs1,
                source_register_2=rs2,
                immediate=imm if operation not in (R_ALU | BRANCHES | JUMPS) else None,
                address=addr if operation in (LOADS | STORES) else None,
                branch_taken=state.branch_taken_current
                if operation in BRANCHES
                else None,
            )
        else:
            # Standard logging format
            cocotb.log.info(
                f"cycle {cycle} instr {operation}, pc_cur {state.program_counter_current}, "
                f"expected_pc {expected_pc}, "
                f"rs1 {rs1}, rs2 {rs2}, "
                f"wb_value {rd_wb_value} to rd {rd_to_update}"
            )
            addr = (state.register_file_previous[rs1] + imm) & MASK32
            if operation in LOADS:
                cocotb.log.info(f"cycle {cycle} loading from address {addr}")
            if operation in STORES:
                cocotb.log.info(f"cycle {cycle} storing to address {addr}")

        # Wait for rising edge (instruction sampled by DUT on this edge)
        await RisingEdge(dut_if.clock)

        # Track CSR counters: cycle increments every clock, instret when instruction retires
        state.increment_cycle_counter()
        state.increment_instret_counter()  # Each iteration = one instruction retired

        # ====================================================================
        # Step 6: Advance Software State for Next Cycle
        # ====================================================================
        # Move PC through pipeline stages
        # All control flow (JAL, JALR, branches) now resolved in EX stage with same timing
        pc_update = CPUModel.calculate_internal_pc_update(
            state,
            operation,
            state.register_file_previous[rs1],
            imm,
            offset,
            expected_pc,
        )
        state.update_program_counter(pc_update)

        # Advance register file state through pipeline stages
        state.advance_register_state()

    # ========================================================================
    # Test Completion Phase
    # ========================================================================

    # Stop driving new instructions
    await FallingEdge(dut_if.clock)
    wait_cycles = await dut_if.wait_ready()
    state.csr_cycle_counter += wait_cycles  # Track cycles spent waiting for stalls
    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Report test statistics
    if config.use_structured_logging:
        InstructionLogger.log_coverage_summary(
            stats.coverage, config.min_coverage_count
        )
    cocotb.log.info(stats.report())

    # Verify coverage: all instructions must execute > min_coverage_count times
    coverage_issues = stats.check_coverage(config.min_coverage_count)
    if coverage_issues:
        error_message = "Coverage verification failed:\n" + "\n".join(
            f"  - {issue}" for issue in coverage_issues
        )
        cocotb.log.error(error_message)
        raise AssertionError(error_message)

    # Wait for pipeline to drain and all monitors to verify remaining outputs
    await flush_remaining_outputs(dut, state, dut_if)


@cocotb.test()
async def test_random_riscv_regression(dut: Any) -> None:
    """Random RISC-V regression: ALU + branches + jumps + loads/stores."""
    await test_random_riscv_regression_main(dut=dut)


@cocotb.test()
async def test_random_riscv_regression_force_one_address(dut: Any) -> None:
    """Random RISC-V regression but forcing one address to stress hazards and cache."""
    config = TestConfig(force_one_address=True)
    await test_random_riscv_regression_main(dut=dut, config=config)
