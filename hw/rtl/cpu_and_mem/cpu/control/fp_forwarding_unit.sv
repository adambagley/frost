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
 * Floating-Point Data Forwarding Unit - RAW hazard resolution for FP registers
 *
 * This module eliminates pipeline stalls due to FP data dependencies by
 * forwarding results from later pipeline stages to the EX stage FPU inputs.
 *
 * Unlike the integer forwarding unit, FP has:
 *   - 3 source registers (for FMA instructions: fs1, fs2, fs3)
 *   - No hardwired zero register (all f0-f31 are writable)
 *   - Simpler data path (no cache hit handling, no AMO)
 *
 * Forwarding Paths:
 * =================
 *   From MA stage (1 cycle ahead):
 *     - FP compute result from EX stage
 *     - FLW data from memory (after load-use stall)
 *
 *   From WB stage (2 cycles ahead):
 *     - Final FP writeback data
 *
 *   From FP Regfile (via ID->EX):
 *     - Normal register read (no hazard)
 *
 * Priority: MA > WB > Regfile (same as integer forwarding)
 */
module fp_forwarding_unit #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,

    // Control inputs
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,

    // Data inputs for forwarding decisions
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id,
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input riscv_pkg::from_ex_comb_t  i_from_ex_comb,
    input riscv_pkg::from_ex_to_ma_t i_from_ex_to_ma,
    input riscv_pkg::from_ma_comb_t  i_from_ma_comb,
    input riscv_pkg::from_ma_to_wb_t i_from_ma_to_wb,

    // Forwarded FP register values output to Execute stage
    output riscv_pkg::fp_fwd_to_ex_t o_fp_fwd_to_ex
);

  // FP source register values from register file (registered in ID stage)
  logic [XLEN-1:0] fp_source_reg_1_raw_value;
  logic [XLEN-1:0] fp_source_reg_2_raw_value;
  logic [XLEN-1:0] fp_source_reg_3_raw_value;

  // Unlike integer registers, FP has no hardwired zero register
  assign fp_source_reg_1_raw_value = i_from_id_to_ex.fp_source_reg_1_data;
  assign fp_source_reg_2_raw_value = i_from_id_to_ex.fp_source_reg_2_data;
  assign fp_source_reg_3_raw_value = i_from_id_to_ex.fp_source_reg_3_data;

  // Forwarding control signals - indicate when to forward from each stage
  logic forward_fp_rs1_from_ma;
  logic forward_fp_rs2_from_ma;
  logic forward_fp_rs3_from_ma;
  logic forward_fp_rs1_from_wb;
  logic forward_fp_rs2_from_wb;
  logic forward_fp_rs3_from_wb;

  // Data to forward from Memory Access stage (registered)
  logic [XLEN-1:0] fp_register_write_data_ma;

  // Detect when FP forwarding is needed (RAW hazard detection)
  // Uses early source registers from PD stage for better timing
  // NOTE: Only update when not stalled, except for the FP load-in-MA hazard.
  // That hazard stalls while the consumer is still in ID, so we must update the
  // forward flags during that stall to have them ready for the next cycle.
  logic allow_forward_update;
  assign allow_forward_update = ~i_pipeline_ctrl.stall ||
                                i_pipeline_ctrl.stall_for_fp_load_ma_hazard;

  always_ff @(posedge i_clk) begin
    if (allow_forward_update) begin
      if (i_pipeline_ctrl.stall_for_fp_load_ma_hazard) begin
        // Special case: FP load is in MA and consumer is still in ID.
        forward_fp_rs1_from_ma <= i_from_ex_to_ma.is_fp_load &&
            (i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.source_reg_1_early);
        forward_fp_rs2_from_ma <= i_from_ex_to_ma.is_fp_load &&
            (i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.source_reg_2_early);
        forward_fp_rs3_from_ma <= i_from_ex_to_ma.is_fp_load &&
            (i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.fp_source_reg_3_early);

        forward_fp_rs1_from_wb <= i_from_ex_to_ma.fp_regfile_write_enable &&
            (i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.source_reg_1_early);
        forward_fp_rs2_from_wb <= i_from_ex_to_ma.fp_regfile_write_enable &&
            (i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.source_reg_2_early);
        forward_fp_rs3_from_wb <= i_from_ex_to_ma.fp_regfile_write_enable &&
            (i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.fp_source_reg_3_early);
      end else begin
        // Forward from MA stage if FP instruction in EX writes to FP register needed in ID
        forward_fp_rs1_from_ma <=
            (i_from_ex_comb.fp_regfile_write_enable | i_from_id_to_ex.is_fp_load) &&
            i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_1_early;

        forward_fp_rs2_from_ma <=
            (i_from_ex_comb.fp_regfile_write_enable | i_from_id_to_ex.is_fp_load) &&
            i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_2_early;

        forward_fp_rs3_from_ma <=
            (i_from_ex_comb.fp_regfile_write_enable | i_from_id_to_ex.is_fp_load) &&
            i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.fp_source_reg_3_early;

        // Forward from WB stage if FP instruction in MA writes to FP register needed in ID
        // Use fp_dest_reg instead of instruction.dest_reg because for pipelined FPU ops,
        // the instruction has moved on but fp_dest_reg tracks the actual destination.
        forward_fp_rs1_from_wb <=
            i_from_ex_to_ma.fp_regfile_write_enable &&
            i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.source_reg_1_early;

        forward_fp_rs2_from_wb <=
            i_from_ex_to_ma.fp_regfile_write_enable &&
            i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.source_reg_2_early;

        forward_fp_rs3_from_wb <=
            i_from_ex_to_ma.fp_regfile_write_enable &&
            i_from_ex_to_ma.fp_dest_reg == i_from_pd_to_id.fp_source_reg_3_early;
      end
    end
    if (i_pipeline_ctrl.reset) begin
      forward_fp_rs1_from_ma <= 1'b0;
      forward_fp_rs2_from_ma <= 1'b0;
      forward_fp_rs3_from_ma <= 1'b0;
      forward_fp_rs1_from_wb <= 1'b0;
      forward_fp_rs2_from_wb <= 1'b0;
      forward_fp_rs3_from_wb <= 1'b0;
    end
  end

  // Select data to forward from MA stage.
  // For FP load-use stalls, capture the memory data when the stall is asserted so it
  // stays stable through the stall and the following cycle.
  // Also capture when pipelined FPU result becomes ready during stall - this ensures
  // the result is available when the stall ends, since the normal capture condition
  // (~stall) uses OLD stall value at posedge and would miss the capture.
  always_ff @(posedge i_clk)
    if (i_pipeline_ctrl.stall_for_load_use_hazard && i_from_ex_to_ma.is_fp_load)
      // Capture the stall-aligned memory data for FP load forwarding.
      fp_register_write_data_ma <= i_from_ma_comb.data_memory_read_data;
    else if (i_pipeline_ctrl.stall_for_fpu_inflight_hazard &&
             i_from_ex_comb.fp_regfile_write_enable)
      // FPU inflight hazard: capture when pipelined result becomes ready
      fp_register_write_data_ma <= i_from_ex_comb.fp_result;
    else if (~i_pipeline_ctrl.stall)
      // Normal case: forward FP compute result
      fp_register_write_data_ma <= i_from_ex_comb.fp_result;

  // Final multiplexing: select forwarded value or register file value
  // Priority order: MA stage forward > WB stage forward > Register file
  //
  // For FP load-use forwarding, use the captured data during the stall and the
  // following cycle to keep load results stable for the dependent instruction.
  // Track load-use stalls specifically so unrelated stalls don't force stale captures.
  logic load_use_stall_registered;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) load_use_stall_registered <= 1'b0;
    else load_use_stall_registered <= i_pipeline_ctrl.stall_for_load_use_hazard;
  end

  logic use_fp_load_capture;
  assign use_fp_load_capture = i_pipeline_ctrl.stall_for_load_use_hazard |
                               load_use_stall_registered;

  // Direct EX-stage bypass: handle FP load in MA feeding current EX instruction.
  // These combinational signals check is_fp_load AND the actual register match,
  // preventing stale registered signals from causing incorrect forwarding.
  logic ex_fp_load_rs1_match;
  assign ex_fp_load_rs1_match = i_from_ex_to_ma.is_fp_load &&
                                (i_from_ex_to_ma.fp_dest_reg ==
                                 i_from_id_to_ex.instruction.source_reg_1);

  // Combinational register match for MA/WB stage forwarding (guards against stale signals)
  logic ma_dest_matches_rs1;
  assign ma_dest_matches_rs1 = (i_from_ex_to_ma.fp_dest_reg ==
                                i_from_id_to_ex.instruction.source_reg_1);
  logic wb_dest_matches_rs1;
  assign wb_dest_matches_rs1 = (i_from_ma_to_wb.fp_dest_reg ==
                                i_from_id_to_ex.instruction.source_reg_1);

  assign o_fp_fwd_to_ex.fp_source_reg_1_value =
      ex_fp_load_rs1_match ?
          (use_fp_load_capture ? fp_register_write_data_ma :
                                 i_from_ma_comb.data_memory_read_data) :
      (forward_fp_rs1_from_ma && ma_dest_matches_rs1) ? fp_register_write_data_ma :
      (forward_fp_rs1_from_wb && wb_dest_matches_rs1) ? i_from_ma_to_wb.fp_regfile_write_data :
      fp_source_reg_1_raw_value;

  logic ex_fp_load_rs2_match;
  assign ex_fp_load_rs2_match = i_from_ex_to_ma.is_fp_load &&
                                (i_from_ex_to_ma.fp_dest_reg ==
                                 i_from_id_to_ex.instruction.source_reg_2);

  logic ma_dest_matches_rs2;
  assign ma_dest_matches_rs2 = (i_from_ex_to_ma.fp_dest_reg ==
                                i_from_id_to_ex.instruction.source_reg_2);
  logic wb_dest_matches_rs2;
  assign wb_dest_matches_rs2 = (i_from_ma_to_wb.fp_dest_reg ==
                                i_from_id_to_ex.instruction.source_reg_2);

  assign o_fp_fwd_to_ex.fp_source_reg_2_value =
      ex_fp_load_rs2_match ?
          (use_fp_load_capture ? fp_register_write_data_ma :
                                 i_from_ma_comb.data_memory_read_data) :
      (forward_fp_rs2_from_ma && ma_dest_matches_rs2) ? fp_register_write_data_ma :
      (forward_fp_rs2_from_wb && wb_dest_matches_rs2) ? i_from_ma_to_wb.fp_regfile_write_data :
      fp_source_reg_2_raw_value;

  logic ex_fp_load_rs3_match;
  assign ex_fp_load_rs3_match = i_from_ex_to_ma.is_fp_load &&
                                (i_from_ex_to_ma.fp_dest_reg ==
                                 i_from_id_to_ex.instruction.funct7[6:2]);

  logic ma_dest_matches_rs3;
  assign ma_dest_matches_rs3 = (i_from_ex_to_ma.fp_dest_reg ==
                                i_from_id_to_ex.instruction.funct7[6:2]);
  logic wb_dest_matches_rs3;
  assign wb_dest_matches_rs3 = (i_from_ma_to_wb.fp_dest_reg ==
                                i_from_id_to_ex.instruction.funct7[6:2]);

  assign o_fp_fwd_to_ex.fp_source_reg_3_value =
      ex_fp_load_rs3_match ?
          (use_fp_load_capture ? fp_register_write_data_ma :
                                 i_from_ma_comb.data_memory_read_data) :
      (forward_fp_rs3_from_ma && ma_dest_matches_rs3) ? fp_register_write_data_ma :
      (forward_fp_rs3_from_wb && wb_dest_matches_rs3) ? i_from_ma_to_wb.fp_regfile_write_data :
      fp_source_reg_3_raw_value;

  // ===========================================================================
  // Capture Bypass for Pipelined FPU Operations
  // ===========================================================================
  // Pipelined FPU operations (FADD, FMUL, FMA, etc.) capture their operands
  // at posedge when entering EX. At this instant, the registered forwarding
  // signals have the OLD values (for the previous instruction), but the
  // combinational FP result from EX has the producer's CORRECT result.
  //
  // TIMING AT CAPTURE POSEDGE:
  // - Producer (single-cycle FP op like FMV.W.X) is in EX, transitioning to MA
  // - Consumer (pipelined op like FADD) is in ID, transitioning to EX
  // - i_from_ex_comb.fp_result = producer's result (computed from OLD registered inputs)
  // - The combinational result is CORRECT because OLD inputs = producer's inputs
  //
  // The capture bypass provides the EX result directly to the pipelined FPU.

  // Track consumer's source registers through the pipeline
  // When consumer is in PD: source_reg_*_early is available
  // When consumer enters ID (posedge): id_source_reg_* captures it
  // When consumer enters EX (posedge): OLD id_source_reg_* = consumer's sources
  logic [4:0] id_source_reg_1, id_source_reg_2, id_fp_source_reg_3;

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      id_source_reg_1 <= 5'b0;
      id_source_reg_2 <= 5'b0;
      id_fp_source_reg_3 <= 5'b0;
    end else if (~i_pipeline_ctrl.stall) begin
      id_source_reg_1 <= i_from_pd_to_id.source_reg_1_early;
      id_source_reg_2 <= i_from_pd_to_id.source_reg_2_early;
      id_fp_source_reg_3 <= i_from_pd_to_id.fp_source_reg_3_early;
    end
  end

  // Capture bypass detection: Does producer (in EX) write to consumer's source?
  // At capture posedge, i_from_ex_comb uses OLD registered inputs (= producer's info)
  // and id_source_reg_* has OLD values (= consumer's sources from when it was in PD)
  assign o_fp_fwd_to_ex.capture_bypass_rs1 =
      i_from_ex_comb.fp_regfile_write_enable &&
      i_from_ex_comb.fp_dest_reg == id_source_reg_1;

  assign o_fp_fwd_to_ex.capture_bypass_rs2 =
      i_from_ex_comb.fp_regfile_write_enable &&
      i_from_ex_comb.fp_dest_reg == id_source_reg_2;

  assign o_fp_fwd_to_ex.capture_bypass_rs3 =
      i_from_ex_comb.fp_regfile_write_enable &&
      i_from_ex_comb.fp_dest_reg == id_fp_source_reg_3;

  // Capture bypass data: use registered fp_result to break combinational loop.
  // FMV.W.X is a bitwise move, so fp_result matches the integer operand.
  logic [XLEN-1:0] fp_result_registered;
  always_ff @(posedge i_clk) begin
    if (~i_pipeline_ctrl.stall) begin
      // Register fp_result to break combinational loop through capture bypass.
      // At capture posedge, the OLD fp_result (producer's result) is captured,
      // which is exactly what the consumer needs.
      fp_result_registered <= i_from_ex_comb.fp_result;
    end
  end

  assign o_fp_fwd_to_ex.capture_bypass_data = fp_result_registered;

  // WB capture bypass: producer in MA, consumer entering EX
  // This handles cases where producer and consumer are 2 cycles apart
  assign o_fp_fwd_to_ex.capture_bypass_rs1_from_wb =
      i_from_ex_to_ma.fp_regfile_write_enable &&
      i_from_ex_to_ma.fp_dest_reg == id_source_reg_1 &&
      !i_from_ex_to_ma.is_fp_load &&
      !o_fp_fwd_to_ex.capture_bypass_rs1;  // MA has priority

  assign o_fp_fwd_to_ex.capture_bypass_rs2_from_wb =
      i_from_ex_to_ma.fp_regfile_write_enable &&
      i_from_ex_to_ma.fp_dest_reg == id_source_reg_2 &&
      !i_from_ex_to_ma.is_fp_load &&
      !o_fp_fwd_to_ex.capture_bypass_rs2;

  assign o_fp_fwd_to_ex.capture_bypass_rs3_from_wb =
      i_from_ex_to_ma.fp_regfile_write_enable &&
      i_from_ex_to_ma.fp_dest_reg == id_fp_source_reg_3 &&
      !i_from_ex_to_ma.is_fp_load &&
      !o_fp_fwd_to_ex.capture_bypass_rs3;

  // Use i_from_ex_to_ma.fp_result instead of i_from_ma_to_wb.fp_regfile_write_data
  // At the capture posedge, the producer (2 cycles ahead) just moved to MA, so its
  // result is in i_from_ex_to_ma (registered at previous posedge), but MA→WB hasn't
  // been updated yet. Using i_from_ex_to_ma.fp_result gives the correct value.
  assign o_fp_fwd_to_ex.capture_bypass_data_wb = i_from_ex_to_ma.fp_result;

  // Detect if incoming instruction (in ID, entering EX) is a pipelined FP op
  // Pipelined ops: FADD, FSUB, FMUL, FDIV, FSQRT, FMADD, FMSUB, FNMADD, FNMSUB
  logic is_pipelined_fp_incoming;
  logic [6:0] incoming_opcode;
  logic [6:0] incoming_funct7;
  assign incoming_opcode = i_from_pd_to_id.instruction.opcode;
  assign incoming_funct7 = i_from_pd_to_id.instruction.funct7;

  always_comb begin
    is_pipelined_fp_incoming = 1'b0;
    case (incoming_opcode)
      riscv_pkg::OPC_FMADD, riscv_pkg::OPC_FMSUB, riscv_pkg::OPC_FNMSUB, riscv_pkg::OPC_FNMADD:
      is_pipelined_fp_incoming = 1'b1;
      riscv_pkg::OPC_OP_FP: begin
        case (incoming_funct7)
          7'b0000000,  // FADD.S
          7'b0000100,  // FSUB.S
          7'b0001000,  // FMUL.S
          7'b0001100,  // FDIV.S
          7'b0101100:  // FSQRT.S
          is_pipelined_fp_incoming = 1'b1;
          default: is_pipelined_fp_incoming = 1'b0;
        endcase
      end
      default: is_pipelined_fp_incoming = 1'b0;
    endcase
  end

  // Register the pipelined detection so it aligns with capture timing
  // At capture posedge, OLD is_pipelined_fp_in_id = true if consumer is pipelined
  logic is_pipelined_fp_in_id;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) is_pipelined_fp_in_id <= 1'b0;
    else if (~i_pipeline_ctrl.stall) is_pipelined_fp_in_id <= is_pipelined_fp_incoming;
  end

  assign o_fp_fwd_to_ex.capture_bypass_is_pipelined = is_pipelined_fp_in_id;

endmodule : fp_forwarding_unit
