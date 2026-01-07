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
 * Branch Prediction Controller
 *
 * Encapsulates the branch prediction logic for the IF stage, including:
 *   - Branch Target Buffer (BTB) instantiation and management
 *   - Prediction gating logic (when to use predictions)
 *   - Prediction registration for pipeline timing alignment
 *   - Holdoff generation for C-extension state clearing
 *
 * TIMING OPTIMIZATION: This module registers prediction outputs and uses
 * only registered control signals for gating decisions. The combinational
 * BTB lookup result is gated by registered holdoff signals, breaking the
 * path from stall logic through prediction to PC calculation.
 *
 * Architecture:
 *   - BTB provides combinational lookup (o_btb_* signals)
 *   - sel_prediction gates when prediction actually redirects PC
 *   - Registered outputs (o_prediction_*_r) align with instruction timing
 *   - prediction_holdoff signals c_ext_state to clear stale buffers
 */
module branch_prediction_controller #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_reset,
    input logic i_stall,
    input logic i_flush,

    // Current PC for BTB lookup
    input logic [XLEN-1:0] i_pc,

    // Control signals for prediction gating (all should be registered for timing)
    input logic i_trap_taken,
    input logic i_mret_taken,
    input logic i_branch_taken,
    input logic i_any_holdoff_safe,     // Registered holdoff signals
    input logic i_is_32bit_spanning,
    input logic i_spanning_wait_for_fetch,
    input logic i_spanning_in_progress,
    input logic i_disable_branch_prediction,

    // BTB update interface (from EX stage)
    input logic            i_btb_update,
    input logic [XLEN-1:0] i_btb_update_pc,
    input logic [XLEN-1:0] i_btb_update_target,
    input logic            i_btb_update_taken,

    // Combinational prediction outputs (for pc_controller next_pc selection)
    output logic            o_predicted_taken,
    output logic [XLEN-1:0] o_predicted_target,

    // Registered prediction outputs (for pipeline stage alignment)
    output logic            o_prediction_used_r,  // Prediction was actually used (registered)
    output logic [XLEN-1:0] o_predicted_target_r, // Target address (registered)

    // Control outputs
    output logic o_prediction_used,  // Prediction used this cycle (for pc_controller)
    output logic o_prediction_holdoff,  // One cycle after prediction (for c_ext_state)
    output logic o_sel_prediction_r,  // Registered sel_prediction (for pc_controller pc_reg)
    output logic o_control_flow_to_halfword_pred  // Prediction targets halfword address
);

  // ===========================================================================
  // BTB Instance
  // ===========================================================================
  logic            btb_hit;
  logic            btb_predicted_taken;
  logic [XLEN-1:0] btb_predicted_target;

  branch_predictor #(
      .XLEN(XLEN)
  ) branch_predictor_inst (
      .i_clk,
      .i_rst(i_reset),

      // Prediction lookup (uses current PC)
      .i_pc(i_pc),
      .o_btb_hit(btb_hit),
      .o_predicted_taken(btb_predicted_taken),
      .o_predicted_target(btb_predicted_target),

      // Update from EX stage
      .i_update(i_btb_update),
      .i_update_pc(i_btb_update_pc),
      .i_update_target(i_btb_update_target),
      .i_update_taken(i_btb_update_taken)
  );

  // ===========================================================================
  // Prediction Gating Logic
  // ===========================================================================
  // sel_prediction determines when a BTB prediction actually redirects the PC.
  // We block predictions in various scenarios to maintain correctness:
  //
  //   - During reset, trap, mret, stall (higher priority control flow)
  //   - During branch taken from EX (actual resolution overrides prediction)
  //   - During holdoff cycles (instruction data is stale)
  //   - During spanning instruction processing (must complete spanning first)
  //   - For halfword-aligned PCs (might be spanning, can't predict safely)
  //   - When branch prediction is disabled (verification mode)
  //
  // TIMING: Uses i_any_holdoff_safe (registered) to break path from branch_taken.

  logic sel_prediction;
  assign sel_prediction = !i_reset && !i_trap_taken && !i_mret_taken && !i_stall &&
                          !i_branch_taken && !i_any_holdoff_safe && btb_predicted_taken &&
                          !i_is_32bit_spanning && !i_spanning_wait_for_fetch &&
                          !i_spanning_in_progress && !i_pc[1] &&
                          !i_disable_branch_prediction;

  // Export combinational prediction for pc_controller
  assign o_predicted_taken = btb_predicted_taken;
  assign o_predicted_target = btb_predicted_target;
  assign o_prediction_used = sel_prediction;

  // Detect prediction to halfword-aligned address
  assign o_control_flow_to_halfword_pred = sel_prediction && btb_predicted_target[1];

  // ===========================================================================
  // Prediction Registration
  // ===========================================================================
  // Register prediction outputs for pipeline timing alignment.
  // When we predict at PC_N in cycle N:
  //   - Cycle N: BTB lookup, sel_prediction computed, PC redirected
  //   - Cycle N+1: Instruction at PC_N arrives, needs registered prediction metadata
  //
  // CRITICAL: Only set registered taken flag if prediction was ACTUALLY USED.
  // If prediction was blocked (e.g., halfword-aligned PC), but we still pass
  // the raw BTB output, EX stage will think we predicted and skip the redirect.

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_prediction_used_r  <= 1'b0;
      o_predicted_target_r <= '0;
      o_sel_prediction_r   <= 1'b0;
    end else if (~i_stall) begin
      // Clear on flush - prediction for flushed instruction is invalid
      o_prediction_used_r  <= i_flush ? 1'b0 : sel_prediction;
      o_predicted_target_r <= btb_predicted_target;
      o_sel_prediction_r   <= i_flush ? 1'b0 : sel_prediction;
    end
  end

  // ===========================================================================
  // Prediction Holdoff Generation
  // ===========================================================================
  // Generate a one-cycle delayed signal after prediction for c_ext_state.
  // This tells c_ext_state to clear stale spanning/buffer state AFTER the
  // branch instruction processes but BEFORE the predicted target.
  //
  // Unlike control_flow_holdoff, this does NOT block is_compressed detection
  // which is needed for correct instruction processing at the branch PC.

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      o_prediction_holdoff <= 1'b0;
    end else if (~i_stall) begin
      // Set holdoff on cycle after prediction; clear on flush
      o_prediction_holdoff <= i_flush ? 1'b0 : sel_prediction;
    end
  end

endmodule : branch_prediction_controller
