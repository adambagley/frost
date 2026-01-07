/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
  Pipeline control unit managing stalls, flushes, and hazard resolution.
  This module orchestrates the overall pipeline flow by detecting and resolving hazards,
  particularly load-use dependencies and multi-cycle multiply/divide operations. It generates
  stall signals when hazards are detected, manages pipeline flushing on branches/traps/MRET,
  and coordinates reset operations including cache resets. The unit handles trap-related
  control: WFI stalls (broken by interrupts), trap entry flush, and MRET flush. It maintains
  pipeline state during stalls by preserving instruction and data values that would otherwise
  be lost due to memory read latencies. It also generates validation signals for testbench
  verification to track instruction flow through the pipeline stages.

  TIMING OPTIMIZATION: Load-use hazard detection is split into two parts to break the
  critical path. The "potential hazard" (dest matches source) is computed from fast
  registered signals, while cache_hit_on_load (which has a long path through forwarding,
  address calculation, and cache lookup) is registered separately. The final hazard
  decision combines these registered signals with minimal logic.
*/
module hazard_resolution_unit #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned NUM_PIPELINE_STAGES = 6,
    // PC becomes valid at ID stage (stage index 2 in 0-indexed 6-stage pipeline: IF=0, PD=1, ID=2...)
    // This offset from the final stage determines when o_pc_vld asserts
    parameter int unsigned PC_VALID_STAGE_OFFSET = 4
) (
    input logic i_clk,
    input logic i_rst,
    // inputs
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id,
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    input riscv_pkg::from_ex_to_ma_t i_from_ex_to_ma,
    input riscv_pkg::from_cache_t i_from_cache,
    // A extension: stall for AMO read-modify-write operations
    input logic i_stall_for_amo,
    // A extension: delayed AMO write enable for regfile bypass
    input logic i_amo_write_enable_delayed,
    // Trap handling - lint suppression for false loop detection (see comment at o_pipeline_ctrl)
    /* verilator lint_off UNOPTFLAT */
    input logic i_trap_taken,
    input logic i_mret_taken,
    /* verilator lint_on UNOPTFLAT */
    input logic i_stall_for_wfi,
    // outputs
    // LINT SUPPRESSION: Some simulators report false combinational loops for packed structs
    // because they treat all fields as potentially interdependent. The actual logic has no
    // loop: stall_for_trap_check is computed WITHOUT trap/mret, breaking the dependency.
    /* verilator lint_off UNOPTFLAT */
    output riscv_pkg::pipeline_ctrl_t o_pipeline_ctrl,
    /* verilator lint_on UNOPTFLAT */
    // Separate output to break AMO combinational loop (not through packed struct).
    // This one IS needed as a separate port because o_stall_excluding_amo computation
    // doesn't include i_stall_for_amo, breaking: stall → AMO check → stall_for_amo → stall
    output logic o_stall_excluding_amo,
    output logic o_rst_done,
    output logic o_vld,
    output logic o_pc_vld
);

  // ===========================================================================
  // Internal Pipeline Control Signals
  // ===========================================================================
  // These internal signals are used throughout the module and then assigned
  // to o_pipeline_ctrl at the end.
  // Lint suppression: False loop detection due to packed struct field interdependency.
  logic pipeline_reset;  // Combined reset (i_rst OR cache_reset_in_progress)
  /* verilator lint_off UNOPTFLAT */
  logic pipeline_stall;  // Final stall signal (gated by trap/mret)
  logic pipeline_flush;  // Flush signal for branch/trap/mret
  /* verilator lint_on UNOPTFLAT */

  // Registered control signals from previous cycle
  logic stall_registered;  // Stall signal from previous cycle
  logic is_load_registered;  // Was previous instruction a load?
  logic branch_taken_registered;  // Was a branch taken in previous cycle?
  logic trap_taken_registered;  // Was a trap taken in previous cycle?
  logic mret_taken_registered;  // Was MRET executed in previous cycle?

  // TIMING OPTIMIZATION: Register multiply "completing next cycle" signal to break critical path.
  // The multiplier exposes o_completing_next_cycle which is 1 when multiply starts.
  // Registering this gives us a signal that becomes 1 on the same cycle as valid_output,
  // allowing us to end the stall early without combinational dependency on multiplier_valid_output.
  logic multiply_completing_reg;
  logic stall_for_multiply_divide_optimized;

  // Load-use hazard detection - split into potential hazard (fast) and cache hit (slow)
  // to break critical timing path. See detailed comments below.
  logic load_potential_hazard;  // Combinational: load might cause hazard (fast path)
  logic amo_potential_hazard;  // Combinational: AMO might cause hazard (fast path)
  logic load_potential_hazard_reg;  // Registered: potential hazard from previous cycle
  logic amo_potential_hazard_reg;  // Registered: potential hazard from previous cycle
  logic cache_hit_on_load_reg;  // Registered: cache hit from previous cycle
  logic load_use_hazard_detected_preliminary;  // Combinational: actual hazard decision
  logic load_use_hazard_detected;  // Current instruction uses data from load
  logic stall_for_load_use_hazard;  // Need to stall due to load-use dependency

  // Track load/AMO instructions to detect back-to-back load-use/AMO-use hazards
  // This prevents consecutive hazards from causing issues and ends hazard stalls
  always_ff @(posedge i_clk)
    if (pipeline_reset) is_load_registered <= 1'b0;
    else if (~pipeline_stall | stall_for_load_use_hazard)
      is_load_registered <= (i_from_ex_to_ma.is_load_instruction |
                             i_from_ex_to_ma.is_amo_instruction) &
                           ~is_load_registered &
                            stall_for_load_use_hazard;

  // Register multiply "completing next cycle" signal to predict completion
  // This breaks the critical timing path from multiplier to stall logic
  always_ff @(posedge i_clk)
    if (pipeline_reset) multiply_completing_reg <= 1'b0;
    else multiply_completing_reg <= i_from_ex_comb.multiply_completing_next_cycle;

  // Optimized stall for multiply/divide:
  // - Multiply: use registered prediction signal (breaks critical path, 1-cycle stall)
  // - Divide: use ALU's stall signal (takes 17+ cycles)
  assign stall_for_multiply_divide_optimized =
      (i_from_id_to_ex.is_multiply & ~multiply_completing_reg) |
      (i_from_id_to_ex.is_divide & i_from_ex_comb.stall_for_multiply_divide);

  // Hazard detection and stall generation
  // Priority: multiply/divide stalls take precedence over load-use stalls
  // Use optimized multiply stall for correct behavior with timing optimization
  assign load_use_hazard_detected = load_use_hazard_detected_preliminary & ~is_load_registered;
  assign stall_for_load_use_hazard = load_use_hazard_detected &
                                     ~stall_for_multiply_divide_optimized;

  // Combine all stall sources (before trap/mret gating, for trap unit to use without loop)
  // Use optimized multiply stall for correct behavior with timing optimization
  logic stall_sources;
  assign stall_sources = stall_for_multiply_divide_optimized |
                         stall_for_load_use_hazard |
                         i_stall_for_amo |
                         i_stall_for_wfi;

  // ===========================================================================
  // Internal Pipeline Control Signal Generation
  // ===========================================================================
  // Generate internal signals first, then assign to output struct at the end.
  // Note: WFI stall is included but trap_taken/mret_taken override it (break WFI on interrupt)
  assign pipeline_reset = i_rst | i_from_cache.cache_reset_in_progress;
  assign pipeline_stall = stall_sources & ~i_trap_taken & ~i_mret_taken;

  // Reset is complete when cache initialization finishes
  assign o_rst_done = ~i_from_cache.cache_reset_in_progress;

  /*
    Preserve fetched instruction and data during stalls.
    Required due to one-cycle memory read latency - when pipeline stalls,
    we must maintain the same instruction/data for multiple cycles.
    Clear on flush to prevent just_unstalled from triggering after a flush -
    after flush, we should use live values, not saved values from before flush.
  */
  always_ff @(posedge i_clk)
    stall_registered <= (pipeline_reset || pipeline_flush) ? 1'b0 : pipeline_stall;

  // Register branch taken signal for pipeline flush control
  // With 6-stage pipeline, flush for 2 cycles and observe in both PD and ID stages
  //
  // CRITICAL: Clear registered signals during stall to prevent spurious flush after stall.
  // Problem scenario without this fix:
  //   1. Misprediction in cycle N, branch_taken=1, flush=1
  //   2. Stall begins in N+1, flush blocked by ~stall, but branch_taken_registered=1 held
  //   3. Stall ends in N+3, stale branch_taken_registered=1 causes flush=1
  //   4. Correct instruction arriving from memory is incorrectly discarded!
  // Fix: Clear registered signals during stall so they don't persist and cause late flushes.
  always_ff @(posedge i_clk)
    if (pipeline_reset) begin
      branch_taken_registered <= 1'b0;
    end else if (pipeline_stall) begin
      // Clear during stall to prevent stale flush after stall ends
      branch_taken_registered <= 1'b0;
    end else begin
      branch_taken_registered <= i_from_ex_comb.branch_taken;
    end

  // Register trap/mret signals to extend flush (same as branches)
  // Without this, instructions in IF/PD stages when trap/mret occurs can proceed through
  // the pipeline and incorrectly write to registers after the trap returns
  // Clear during stall (same fix as branch_taken_registered above)
  always_ff @(posedge i_clk)
    if (pipeline_reset) begin
      trap_taken_registered <= 1'b0;
      mret_taken_registered <= 1'b0;
    end else if (pipeline_stall) begin
      // Clear during stall to prevent stale flush after stall ends
      trap_taken_registered <= 1'b0;
      mret_taken_registered <= 1'b0;
    end else begin
      trap_taken_registered <= i_trap_taken;
      mret_taken_registered <= i_mret_taken;
    end

  // Need to flush pipeline for 2 cycles following a taken branch/jump, trap, or MRET
  // This clears out instructions that were fetched before the branch/jump/trap resolved
  // All branches and jumps (JAL, JALR, conditional) are now resolved in EX stage
  // Trap/MRET also cause flush: need to discard instructions in PD and ID stages
  // Flush is observed in both PD and ID stages
  assign pipeline_flush = (i_from_ex_comb.branch_taken | branch_taken_registered |
                           i_trap_taken | i_mret_taken |
                           trap_taken_registered | mret_taken_registered) &
                          ~pipeline_stall;

  // ===========================================================================
  // Load-use and AMO-use Hazard Detection (Timing-Optimized)
  // ===========================================================================
  // CRITICAL PATH OPTIMIZATION:
  // The original implementation computed cache_hit_on_load and combined it with
  // hazard conditions in a single cycle, creating a long combinational path:
  //   rs1 → regfile → forwarding → address_calc → cache_lookup → cache_hit → hazard_detect → register
  //
  // The optimized approach splits this into:
  //   Cycle N: Compute potential_hazard (fast) and cache_hit (slow) in PARALLEL, register both
  //   Cycle N+1: Combine registered values: actual_hazard = potential_hazard_reg && ~cache_hit_reg
  //
  // This breaks the critical path because:
  //   - potential_hazard uses only registered signals (is_load, dest_reg, source_reg_early)
  //   - cache_hit_on_load (the slow signal) ends at a register, not feeding into more logic
  //   - The final hazard decision in cycle N+1 is just one AND gate
  //
  // Behavior is preserved: stall decision happens at the same time, just computed differently.
  // ===========================================================================

  // Potential hazard detection (FAST PATH - uses only registered signals)
  // These signals are available early in the cycle because they come from pipeline registers.
  logic dest_matches_source;
  assign dest_matches_source =
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_1_early ||
      i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_2_early;

  assign load_potential_hazard =
      i_from_id_to_ex.is_load_instruction &&
      i_from_id_to_ex.instruction.dest_reg != 0 &&
      dest_matches_source;

  assign amo_potential_hazard =
      i_from_id_to_ex.is_amo_instruction &&
      i_from_id_to_ex.instruction.dest_reg != 0 &&
      dest_matches_source;

  // Register the potential hazards and cache hit signal
  // cache_hit_on_load is the SLOW signal (long combinational path), but it now ends at a register
  always_ff @(posedge i_clk) begin
    if (pipeline_reset || pipeline_flush) begin
      load_potential_hazard_reg <= 1'b0;
      amo_potential_hazard_reg <= 1'b0;
      cache_hit_on_load_reg <= 1'b0;
    end else if (~pipeline_stall) begin
      load_potential_hazard_reg <= load_potential_hazard;
      amo_potential_hazard_reg <= amo_potential_hazard;
      cache_hit_on_load_reg <= i_from_cache.cache_hit_on_load;
    end
  end

  // Final hazard decision (SHORT PATH - just one AND gate after registers)
  // Load-use hazard: potential hazard existed AND cache didn't hit (can't forward from cache)
  // AMO-use hazard: always stall (no cache shortcut, result not available until READ phase)
  assign load_use_hazard_detected_preliminary =
      (load_potential_hazard_reg && ~cache_hit_on_load_reg) ||
      amo_potential_hazard_reg;

  // Validation signals for testbench - track instruction progress through pipeline
  // This shift register moves a '1' through each stage, indicating valid instruction flow.
  // Uses explicit shift operator for clarity: shifts left, inserting 1 at LSB each cycle.
  logic [NUM_PIPELINE_STAGES-1:0] validation_shift_register;
  always_ff @(posedge i_clk)
    if (pipeline_reset) validation_shift_register <= '0;
    else if (~pipeline_stall)
      validation_shift_register <= {validation_shift_register[NUM_PIPELINE_STAGES-2:0], 1'b1};

  // Output valid when instruction reaches final stage and pipeline not stalled
  assign o_vld = validation_shift_register[NUM_PIPELINE_STAGES-1] & ~pipeline_stall;
  // PC valid occurs earlier in pipeline (at ID stage)
  assign o_pc_vld = validation_shift_register[NUM_PIPELINE_STAGES-PC_VALID_STAGE_OFFSET] &
                   ~pipeline_stall;

  // ===========================================================================
  // Output Struct Assignment
  // ===========================================================================
  // Assign internal signals to output struct. This keeps all output assignments
  // in one place and avoids Verilator UNOPTFLAT warnings from using output
  // struct fields within the same module.
  assign o_pipeline_ctrl.reset = pipeline_reset;
  assign o_pipeline_ctrl.stall = pipeline_stall;
  assign o_pipeline_ctrl.flush = pipeline_flush;
  assign o_pipeline_ctrl.stall_registered = stall_registered;
  assign o_pipeline_ctrl.stall_for_load_use_hazard = stall_for_load_use_hazard;
  // Stall check for trap unit - doesn't include trap/mret gating to break combinatorial loop
  assign o_pipeline_ctrl.stall_for_trap_check = stall_sources;
  // Expose raw hazard detection for forwarding unit.
  assign o_pipeline_ctrl.load_use_hazard_detected = load_use_hazard_detected;
  // Stall sources excluding AMO - breaks combinational loop with AMO unit.
  // AMO unit checks this to see if there are other stalls before starting an AMO operation.
  // This excludes i_stall_for_amo, preventing: stall → AMO check → stall_for_amo → stall
  // NOTE: This is a separate output port (not through packed struct) to avoid false loop detection.
  assign o_stall_excluding_amo = stall_for_multiply_divide_optimized |
                                  load_use_hazard_detected |
                                  i_stall_for_wfi;
  // Force regfile write when AMO result is ready (bypass stall_registered)
  assign o_pipeline_ctrl.amo_wb_write_enable = i_amo_write_enable_delayed;
  // Expose registered trap/mret signals for IF stage timing optimization
  assign o_pipeline_ctrl.trap_taken_registered = trap_taken_registered;
  assign o_pipeline_ctrl.mret_taken_registered = mret_taken_registered;

endmodule : hazard_resolution_unit
