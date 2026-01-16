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
  Floating-Point Unit (FPU) Top-Level Module

  This module implements the complete RISC-V F extension (single-precision
  floating-point) by routing operations to specialized sub-units.

  Submodule Hierarchy:
  ====================
    fpu
    ├── fp_adder.sv          Multi-cycle add/subtract (4-cycle, FADD.S, FSUB.S)
    ├── fp_multiplier.sv     Multi-cycle multiply (8-cycle, FMUL.S)
    ├── fp_divider.sv        Sequential divide (~15 cycles, FDIV.S)
    ├── fp_sqrt.sv           Sequential square root (~15 cycles, FSQRT.S)
    ├── fp_fma.sv            Multi-cycle FMA (12-cycle, FMADD/FMSUB/FNMADD/FNMSUB)
    ├── fp_compare.sv        Comparisons and min/max (3-cycle)
    ├── fp_convert.sv        Integer/FP conversions (3-cycle)
    ├── fp_classify.sv       FCLASS.S (1-cycle)
    └── fp_sign_inject.sv    Sign injection (1-cycle, FSGNJ variants)

  Operation Latencies:
  ====================
    2-cycle:  FSGNJ*, FCLASS (registered output for timing)
    3-cycle:  FEQ/FLT/FLE, FMIN/FMAX, FCVT, FMV (multi-cycle, stalls pipeline)
    4-cycle:  FADD.S, FSUB.S (multi-cycle, stalls pipeline)
    8-cycle:  FMUL.S (multi-cycle, stalls pipeline)
    12-cycle: FMADD.S, FMSUB.S, FNMADD.S, FNMSUB.S (multi-cycle, stalls pipeline)
    ~32-cycle: FDIV.S, FSQRT.S (sequential, stalls pipeline)

  Design Note:
  ============
    Multi-cycle operations (adder, multiplier, FMA, convert) use internal state
    machines and capture operands at the start of each operation. This non-pipelined
    design simplifies timing by ensuring operand stability without complex
    capture bypass mechanisms. The pipeline stalls until each operation completes.

  Interface:
  ==========
    - Accepts operation type from instruction decoder
    - Resolves dynamic rounding mode (FRM_DYN -> frm CSR value)
    - Routes operands to appropriate sub-unit
    - Multiplexes results back to pipeline
    - Aggregates exception flags for CSR update
*/
module fpu #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,

    // Operation valid and type
    input logic                 i_valid,
    input riscv_pkg::instr_op_e i_operation,

    // Operands (FP source registers, or integer for FMV.W.X / FCVT.S.W)
    input logic [XLEN-1:0] i_operand_a,   // rs1 / fs1
    input logic [XLEN-1:0] i_operand_b,   // rs2 / fs2
    input logic [XLEN-1:0] i_operand_c,   // fs3 (for FMA only)
    input logic [XLEN-1:0] i_int_operand, // Integer operand for FMV.W.X, FCVT.S.W

    // Destination register - tracked through pipeline for pipelined operations
    input logic [4:0] i_dest_reg,

    // Rounding mode
    input logic [2:0] i_rm_instr,  // Rounding mode from instruction
    input logic [2:0] i_rm_csr,    // Rounding mode from frm CSR

    // Pipeline control
    input logic i_stall,            // External stall (excludes FPU busy)
    input logic i_stall_registered, // Stall in previous cycle

    // Results
    output logic [XLEN-1:0] o_result,         // FP result (or integer for FMV.X.W, FCVT.W.S, etc.)
    output logic            o_valid,          // Result is valid this cycle
    output logic            o_result_to_int,  // Result goes to integer register (not FP)
    output logic [     4:0] o_dest_reg,       // Destination register for this result

    // Stall signal for multi-cycle operations
    output logic o_stall,  // FPU needs more cycles

    // Exception flags
    output riscv_pkg::fp_flags_t o_flags,

    // In-flight destination registers for RAW hazard detection
    // These are destinations of pipelined ops that haven't completed yet
    output logic [4:0] o_inflight_dest_1,  // Adder/mult stage 0
    output logic [4:0] o_inflight_dest_2,  // Adder/mult stage 1
    output logic [4:0] o_inflight_dest_3,  // FMA stage 0
    output logic [4:0] o_inflight_dest_4,  // FMA stage 1
    output logic [4:0] o_inflight_dest_5,  // FMA stage 2
    output logic [4:0] o_inflight_dest_6   // Sequential (div/sqrt)
);

  // ===========================================================================
  // Multi-Cycle Operation Stall Logic
  // ===========================================================================
  // Multi-cycle operations (adder, multiplier, FMA) use internal state machines
  // and signal when they are busy. The CPU pipeline stalls until the result
  // is available. Since operands are captured at the start of each operation,
  // no complex capture bypass logic is needed.

  logic       adder_busy;  // True when adder is computing
  logic       multiplier_busy;  // True when multiplier is computing
  logic       fma_busy;  // True when FMA is computing
  logic       compare_busy;  // True when compare is computing
  logic       convert_busy;  // True when converter is computing

  // ===========================================================================
  // Effective Rounding Mode Resolution
  // ===========================================================================
  // If instruction specifies FRM_DYN (dynamic), use the CSR value.

  logic [2:0] effective_rm;
  assign effective_rm = (i_rm_instr == riscv_pkg::FRM_DYN) ? i_rm_csr : i_rm_instr;

  // ===========================================================================
  // Operation Decode
  // ===========================================================================
  // Determine which sub-unit handles the operation and prepare control signals.

  logic is_fp_op_for_stall;
  logic op_add, op_sub, op_mul, op_div, op_sqrt;
  logic op_fmadd, op_fmsub, op_fnmadd, op_fnmsub;
  logic op_min, op_max, op_eq, op_lt, op_le;
  logic op_sgnj, op_sgnjn, op_sgnjx;
  logic op_cvt_w_s, op_cvt_wu_s, op_cvt_s_w, op_cvt_s_wu;
  logic op_mv_x_w, op_mv_w_x;
  logic op_fclass;

  // Use a small range check to identify FP ops for stall gating.
  // This avoids pulling the full decode into the stall path.
  assign is_fp_op_for_stall = ($unsigned(
      i_operation
  ) >= $unsigned(
      riscv_pkg::FLW
  )) && ($unsigned(
      i_operation
  ) <= $unsigned(
      riscv_pkg::FCLASS_S
  ));

  always_comb begin
    // Default all to 0
    op_add      = 1'b0;
    op_sub      = 1'b0;
    op_mul      = 1'b0;
    op_div      = 1'b0;
    op_sqrt     = 1'b0;
    op_fmadd    = 1'b0;
    op_fmsub    = 1'b0;
    op_fnmadd   = 1'b0;
    op_fnmsub   = 1'b0;
    op_min      = 1'b0;
    op_max      = 1'b0;
    op_eq       = 1'b0;
    op_lt       = 1'b0;
    op_le       = 1'b0;
    op_sgnj     = 1'b0;
    op_sgnjn    = 1'b0;
    op_sgnjx    = 1'b0;
    op_cvt_w_s  = 1'b0;
    op_cvt_wu_s = 1'b0;
    op_cvt_s_w  = 1'b0;
    op_cvt_s_wu = 1'b0;
    op_mv_x_w   = 1'b0;
    op_mv_w_x   = 1'b0;
    op_fclass   = 1'b0;

    case (i_operation)
      riscv_pkg::FADD_S:    op_add = 1'b1;
      riscv_pkg::FSUB_S:    op_sub = 1'b1;
      riscv_pkg::FMUL_S:    op_mul = 1'b1;
      riscv_pkg::FDIV_S:    op_div = 1'b1;
      riscv_pkg::FSQRT_S:   op_sqrt = 1'b1;
      riscv_pkg::FMADD_S:   op_fmadd = 1'b1;
      riscv_pkg::FMSUB_S:   op_fmsub = 1'b1;
      riscv_pkg::FNMADD_S:  op_fnmadd = 1'b1;
      riscv_pkg::FNMSUB_S:  op_fnmsub = 1'b1;
      riscv_pkg::FMIN_S:    op_min = 1'b1;
      riscv_pkg::FMAX_S:    op_max = 1'b1;
      riscv_pkg::FEQ_S:     op_eq = 1'b1;
      riscv_pkg::FLT_S:     op_lt = 1'b1;
      riscv_pkg::FLE_S:     op_le = 1'b1;
      riscv_pkg::FSGNJ_S:   op_sgnj = 1'b1;
      riscv_pkg::FSGNJN_S:  op_sgnjn = 1'b1;
      riscv_pkg::FSGNJX_S:  op_sgnjx = 1'b1;
      riscv_pkg::FCVT_W_S:  op_cvt_w_s = 1'b1;
      riscv_pkg::FCVT_WU_S: op_cvt_wu_s = 1'b1;
      riscv_pkg::FCVT_S_W:  op_cvt_s_w = 1'b1;
      riscv_pkg::FCVT_S_WU: op_cvt_s_wu = 1'b1;
      riscv_pkg::FMV_X_W:   op_mv_x_w = 1'b1;
      riscv_pkg::FMV_W_X:   op_mv_w_x = 1'b1;
      riscv_pkg::FCLASS_S:  op_fclass = 1'b1;
      default:              ;
    endcase
  end

  // Group operations by sub-unit
  logic use_adder, use_multiplier, use_divider, use_sqrt, use_fma;
  logic use_compare, use_convert, use_classify, use_sign_inject;

  assign use_adder = op_add | op_sub;
  assign use_multiplier = op_mul;
  assign use_divider = op_div;
  assign use_sqrt = op_sqrt;
  assign use_fma = op_fmadd | op_fmsub | op_fnmadd | op_fnmsub;
  assign use_compare = op_min | op_max | op_eq | op_lt | op_le;
  assign use_convert = op_cvt_w_s | op_cvt_wu_s | op_cvt_s_w | op_cvt_s_wu | op_mv_x_w | op_mv_w_x;
  assign use_classify = op_fclass;
  assign use_sign_inject = op_sgnj | op_sgnjn | op_sgnjx;

  // ===========================================================================
  // Sub-Unit Instantiations
  // ===========================================================================

  // --- Adder (FADD.S, FSUB.S) ---
  // Non-pipelined 3-cycle adder: captures operands at start, busy until done
  logic                 [XLEN-1:0] adder_result;
  logic                            adder_valid;
  riscv_pkg::fp_flags_t            adder_flags;

  // Adder busy detection: registered signal tracks when operation is in progress
  // The fpu_entering_ex_hazard in hazard_resolution_unit handles stalling on
  // the cycle when FADD enters EX (before adder_started is set).
  //
  // IMPORTANT: adder_busy includes ~adder_valid so stall releases when result is ready.
  // The clearing of adder_started must have priority over setting to prevent
  // re-triggering on the same stalled instruction when valid goes high.
  // Adder busy signal: asserted after the start cycle until result is valid.
  // Start-cycle stall is handled by the top-level fpu_active gating.
  //
  // Adder tracking: We need to prevent re-triggering the same instruction during stall.
  // When the pipeline is stalled for the adder, the same FADD instruction stays in
  // i_from_id_to_ex. If we allowed starting when adder_valid=1, we'd restart the same
  // instruction. Instead, only allow starting when completely idle (~adder_started).
  // The pipeline must advance (at next posedge) before a new instruction enters EX.
  logic                            adder_started;
  logic                            adder_can_start;
  logic                            adder_start;
  assign adder_can_start = ~adder_started;  // Can only start when idle
  assign adder_start = i_valid & use_adder & adder_can_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) adder_started <= 1'b0;
    else if (adder_valid) adder_started <= 1'b0;  // Clear when operation completes
    else if (adder_start) adder_started <= 1'b1;  // Set when starting new operation
  end
  assign adder_busy = adder_started & ~adder_valid;

  fp_adder adder_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(adder_start),  // Only start when idle
      .i_operand_a(i_operand_a),
      .i_operand_b(i_operand_b),
      .i_is_subtract(op_sub),
      .i_rounding_mode(effective_rm),
      .i_stall(1'b0),  // Not used in non-pipelined mode
      .o_result(adder_result),
      .o_valid(adder_valid),
      .o_flags(adder_flags)
  );

  // --- Multiplier (FMUL.S) ---
  // Non-pipelined 8-cycle multiplier: captures operands at start, busy until done
  logic                 [XLEN-1:0] multiplier_result;
  logic                            multiplier_valid;
  riscv_pkg::fp_flags_t            multiplier_flags;

  // Multiplier tracking: same logic as adder - only start when idle to prevent
  // re-triggering the same stalled instruction.
  logic                            multiplier_started;
  logic                            multiplier_can_start;
  logic                            multiplier_start;
  assign multiplier_can_start = ~multiplier_started;
  assign multiplier_start = i_valid & use_multiplier & multiplier_can_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) multiplier_started <= 1'b0;
    else if (multiplier_valid) multiplier_started <= 1'b0;  // Clear when operation completes
    else if (multiplier_start) multiplier_started <= 1'b1;
  end
  assign multiplier_busy = multiplier_started & ~multiplier_valid;

  fp_multiplier multiplier_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(multiplier_start),
      .i_operand_a(i_operand_a),
      .i_operand_b(i_operand_b),
      .i_rounding_mode(effective_rm),
      .i_stall(1'b0),  // Not used in non-pipelined mode
      .o_result(multiplier_result),
      .o_valid(multiplier_valid),
      .o_flags(multiplier_flags)
  );

  // --- Divider (FDIV.S) ---
  logic                 [XLEN-1:0] divider_result;
  logic                            divider_valid;
  logic                            divider_stall;
  riscv_pkg::fp_flags_t            divider_flags;

  // --- Square Root (FSQRT.S) ---
  logic                 [XLEN-1:0] sqrt_result;
  logic                            sqrt_valid;
  logic                            sqrt_stall;
  riscv_pkg::fp_flags_t            sqrt_flags;

  // Sequential op tracking (divider/sqrt): prevent re-trigger on stalled instruction.
  logic                            seq_started;
  logic                            seq_can_start;
  logic                            divider_start;
  logic                            sqrt_start;
  logic                            seq_start;

  // Can only start when not already started
  assign seq_can_start = ~seq_started;
  assign divider_start = i_valid & use_divider & seq_can_start;
  assign sqrt_start = i_valid & use_sqrt & seq_can_start;
  assign seq_start = divider_start | sqrt_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) seq_started <= 1'b0;
    else if (divider_valid || sqrt_valid) seq_started <= 1'b0;  // Clear when op completes
    else if (seq_start) begin
      seq_started <= 1'b1;  // Set when starting new sequential op
    end
  end

  fp_divider divider_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(divider_start),
      .i_operand_a(i_operand_a),
      .i_operand_b(i_operand_b),
      .i_rounding_mode(effective_rm),
      .o_result(divider_result),
      .o_valid(divider_valid),
      .o_stall(divider_stall),
      .o_flags(divider_flags)
  );

  fp_sqrt sqrt_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(sqrt_start),
      .i_operand(i_operand_a),
      .i_rounding_mode(effective_rm),
      .o_result(sqrt_result),
      .o_valid(sqrt_valid),
      .o_stall(sqrt_stall),
      .o_flags(sqrt_flags)
  );

  // --- FMA (FMADD, FMSUB, FNMADD, FNMSUB) ---
  // FMADD:  (rs1 * rs2) + rs3      -> negate_product=0, negate_c=0
  // FMSUB:  (rs1 * rs2) - rs3      -> negate_product=0, negate_c=1
  // FNMADD: -(rs1 * rs2) - rs3     -> negate_product=1, negate_c=1
  // FNMSUB: -(rs1 * rs2) + rs3     -> negate_product=1, negate_c=0
  logic fma_negate_product, fma_negate_c;
  assign fma_negate_product = op_fnmadd | op_fnmsub;
  assign fma_negate_c       = op_fmsub | op_fnmadd;

  logic                 [XLEN-1:0] fma_result;
  logic                            fma_valid;
  riscv_pkg::fp_flags_t            fma_flags;

  // FMA tracking: same logic as adder - only start when idle to prevent
  // re-triggering the same stalled instruction.
  logic                            fma_started;
  logic                            fma_can_start;
  logic                            fma_start;
  assign fma_can_start = ~fma_started;
  assign fma_start = i_valid & use_fma & fma_can_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) fma_started <= 1'b0;
    else if (fma_valid) fma_started <= 1'b0;  // Clear when operation completes
    else if (fma_start) fma_started <= 1'b1;
  end
  assign fma_busy = fma_started & ~fma_valid;

  fp_fma fma_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(fma_start),
      .i_operand_a(i_operand_a),
      .i_operand_b(i_operand_b),
      .i_operand_c(i_operand_c),
      .i_negate_product(fma_negate_product),
      .i_negate_c(fma_negate_c),
      .i_rounding_mode(effective_rm),
      .i_stall(1'b0),  // Not used in non-pipelined mode
      .o_result(fma_result),
      .o_valid(fma_valid),
      .o_flags(fma_flags)
  );

  // --- Compare (FEQ, FLT, FLE, FMIN, FMAX) ---
  // Multi-cycle 3-cycle compare: captures operands at start, busy until done
  logic                 [XLEN-1:0] compare_result;
  logic                            compare_is_compare;
  logic                            compare_valid;
  riscv_pkg::fp_flags_t            compare_flags;

  // Compare tracking: same logic as adder - only start when idle to prevent
  // re-triggering the same stalled instruction.
  logic                            compare_started;
  logic                            compare_can_start;
  logic                            compare_start;
  assign compare_can_start = ~compare_started;
  assign compare_start = i_valid & use_compare & compare_can_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) compare_started <= 1'b0;
    else if (compare_valid) compare_started <= 1'b0;  // Clear when operation completes
    else if (compare_start) compare_started <= 1'b1;
  end
  assign compare_busy = compare_started & ~compare_valid;

  fp_compare compare_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(compare_start),
      .i_operand_a(i_operand_a),
      .i_operand_b(i_operand_b),
      .i_operation(i_operation),
      .o_result(compare_result),
      .o_is_compare(compare_is_compare),
      .o_valid(compare_valid),
      .o_flags(compare_flags)
  );

  // --- Convert (FCVT.W.S, FCVT.WU.S, FCVT.S.W, FCVT.S.WU, FMV.X.W, FMV.W.X) ---
  // Multi-cycle converter: captures operands at start, busy until done
  logic                 [XLEN-1:0] convert_fp_result;
  logic                 [XLEN-1:0] convert_int_result;
  logic                            convert_is_fp_to_int;
  logic                            convert_valid;
  riscv_pkg::fp_flags_t            convert_flags;

  // Convert tracking: same logic as adder - only start when idle to prevent
  // re-triggering the same stalled instruction.
  logic                            convert_started;
  logic                            convert_can_start;
  logic                            convert_start;
  assign convert_can_start = ~convert_started;
  assign convert_start = i_valid & use_convert & convert_can_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) convert_started <= 1'b0;
    else if (convert_valid) convert_started <= 1'b0;  // Clear when operation completes
    else if (convert_start) convert_started <= 1'b1;
  end
  assign convert_busy = convert_started & ~convert_valid;

  fp_convert convert_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(convert_start),
      .i_fp_operand(i_operand_a),
      .i_int_operand(i_int_operand),
      .i_operation(i_operation),
      .i_rounding_mode(effective_rm),
      .o_fp_result(convert_fp_result),
      .o_int_result(convert_int_result),
      .o_is_fp_to_int(convert_is_fp_to_int),
      .o_valid(convert_valid),
      .o_flags(convert_flags)
  );

  // --- Classify (FCLASS.S) ---
  // 2-cycle operation to break timing path through FP forwarding
  logic [XLEN-1:0] classify_result;
  logic            classify_valid;
  logic            classify_busy;

  // Classify tracking: same pattern as other multi-cycle ops
  logic            classify_started;
  logic            classify_can_start;
  logic            classify_start;
  assign classify_can_start = ~classify_started;
  assign classify_start = i_valid & use_classify & classify_can_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) classify_started <= 1'b0;
    else if (classify_valid) classify_started <= 1'b0;
    else if (classify_start) classify_started <= 1'b1;
  end

  fp_classify classify_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(classify_start),
      .i_operand(i_operand_a),
      .o_result(classify_result),
      .o_valid(classify_valid),
      .o_busy(classify_busy)
  );

  // --- Sign Injection (FSGNJ, FSGNJN, FSGNJX) ---
  // 2-cycle operation to break timing path through FP forwarding
  logic [XLEN-1:0] sign_inject_result;
  logic            sign_inject_valid;
  logic            sign_inject_busy;

  // Sign inject tracking: same pattern as other multi-cycle ops
  logic            sign_inject_started;
  logic            sign_inject_can_start;
  logic            sign_inject_start;
  assign sign_inject_can_start = ~sign_inject_started;
  assign sign_inject_start = i_valid & use_sign_inject & sign_inject_can_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) sign_inject_started <= 1'b0;
    else if (sign_inject_valid) sign_inject_started <= 1'b0;
    else if (sign_inject_start) sign_inject_started <= 1'b1;
  end

  fp_sign_inject sign_inject_inst (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_valid(sign_inject_start),
      .i_operand_a(i_operand_a),
      .i_operand_b(i_operand_b),
      .i_operation(i_operation),
      .o_result(sign_inject_result),
      .o_valid(sign_inject_valid),
      .o_busy(sign_inject_busy)
  );

  // ===========================================================================
  // Result Multiplexing
  // ===========================================================================
  // Select result based on operation type and track which operations produce
  // results for integer registers vs FP registers.

  // Operations that produce integer results (go to integer regfile)
  logic result_is_integer;
  assign result_is_integer = op_cvt_w_s | op_cvt_wu_s | op_mv_x_w |
                            op_eq | op_lt | op_le | op_fclass;

  // ===========================================================================
  // Destination Register Tracking (Simplified for Non-Pipelined Mode)
  // ===========================================================================
  // For multi-cycle operations, capture dest_reg at start and hold until done.
  // Since operations aren't pipelined, we only need one register per unit type.

  logic [4:0] dest_reg_adder;  // Destination for adder operation
  logic [4:0] dest_reg_multiplier;  // Destination for multiplier operation
  logic [4:0] dest_reg_fma;  // Destination for FMA operation
  logic [4:0] dest_reg_compare;  // Destination for compare operation
  logic [4:0] dest_reg_convert;  // Destination for convert operation
  logic [4:0] dest_reg_classify;  // Destination for classify operation
  logic [4:0] dest_reg_sign_inject;  // Destination for sign inject operation
  logic [4:0] dest_reg_seq;  // For sequential operations (div/sqrt)
  logic       dest_reg_seq_valid;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      dest_reg_adder <= 5'b0;
      dest_reg_multiplier <= 5'b0;
      dest_reg_fma <= 5'b0;
      dest_reg_compare <= 5'b0;
      dest_reg_convert <= 5'b0;
      dest_reg_classify <= 5'b0;
      dest_reg_sign_inject <= 5'b0;
      dest_reg_seq <= 5'b0;
      dest_reg_seq_valid <= 1'b0;
    end else begin
      // Capture dest_reg when starting each operation (only when unit is idle)
      if (i_valid && use_adder && adder_can_start) dest_reg_adder <= i_dest_reg;
      if (i_valid && use_multiplier && multiplier_can_start) dest_reg_multiplier <= i_dest_reg;
      if (i_valid && use_fma && fma_can_start) dest_reg_fma <= i_dest_reg;
      if (i_valid && use_compare && compare_can_start) dest_reg_compare <= i_dest_reg;
      if (i_valid && use_convert && convert_can_start) dest_reg_convert <= i_dest_reg;
      if (i_valid && use_classify && classify_can_start) dest_reg_classify <= i_dest_reg;
      if (i_valid && use_sign_inject && sign_inject_can_start) dest_reg_sign_inject <= i_dest_reg;

      // Sequential operations: latch dest_reg at start, clear when done
      if (divider_valid || sqrt_valid) begin
        dest_reg_seq_valid <= 1'b0;
      end else if (seq_start) begin
        dest_reg_seq <= i_dest_reg;
        dest_reg_seq_valid <= 1'b1;
      end
    end
  end

  // Select the appropriate dest_reg based on which operation is producing results
  logic [4:0] selected_dest_reg;
  always_comb begin
    if (adder_valid) selected_dest_reg = dest_reg_adder;
    else if (multiplier_valid) selected_dest_reg = dest_reg_multiplier;
    else if (fma_valid) selected_dest_reg = dest_reg_fma;
    else if (compare_valid) selected_dest_reg = dest_reg_compare;
    else if (convert_valid) selected_dest_reg = dest_reg_convert;
    else if (classify_valid) selected_dest_reg = dest_reg_classify;
    else if (sign_inject_valid) selected_dest_reg = dest_reg_sign_inject;
    else if (divider_valid || sqrt_valid) selected_dest_reg = dest_reg_seq;
    else selected_dest_reg = 5'b0;
  end

  // ===========================================================================
  // Multi-Cycle Result Valid Signal
  // ===========================================================================
  // Results from all multi-cycle ops are valid for exactly one cycle when
  // the state machine completes. No holding needed since the unit stays
  // in output state for one cycle.

  logic multicycle_result_valid;
  assign multicycle_result_valid = adder_valid | multiplier_valid | fma_valid | compare_valid
                                 | convert_valid | classify_valid | sign_inject_valid;

  // Output dest_reg
  assign o_dest_reg = multicycle_result_valid ? selected_dest_reg :
                      (divider_valid || sqrt_valid) ? dest_reg_seq : 5'b0;

  // Result valid from any source
  logic any_valid;
  assign any_valid = multicycle_result_valid | divider_valid | sqrt_valid;

  // Result selection
  // Multi-cycle operations output their result when their state machine
  // completes (valid signal goes high).
  always_comb begin
    o_result = 32'b0;
    o_flags = '0;
    o_result_to_int = 1'b0;

    if (adder_valid) begin
      o_result = adder_result;
      o_flags  = adder_flags;
    end else if (multiplier_valid) begin
      o_result = multiplier_result;
      o_flags  = multiplier_flags;
    end else if (fma_valid) begin
      o_result = fma_result;
      o_flags  = fma_flags;
    end else if (compare_valid) begin
      o_result = compare_result;
      o_result_to_int = compare_is_compare;  // FEQ/FLT/FLE results go to integer register
      o_flags = compare_flags;
    end else if (convert_valid) begin
      o_result = convert_is_fp_to_int ? convert_int_result : convert_fp_result;
      o_result_to_int = convert_is_fp_to_int;
      o_flags = convert_flags;
    end else if (classify_valid) begin
      o_result = classify_result;
      o_result_to_int = 1'b1;  // FCLASS result goes to integer register
    end else if (sign_inject_valid) begin
      o_result = sign_inject_result;
    end else if (divider_valid) begin
      o_result = divider_result;
      o_flags  = divider_flags;
    end else if (sqrt_valid) begin
      o_result = sqrt_result;
      o_flags  = sqrt_flags;
    end
  end

  assign o_valid = any_valid;

  // Stall output for multi-cycle operations.
  // Use a registered active flag plus a small range check to avoid feeding
  // the full operation decode into the stall path.
  logic start_any;
  logic fpu_active;
  assign start_any = adder_start | multiplier_start | fma_start | compare_start |
                     convert_start | classify_start | sign_inject_start | seq_start;

  always_ff @(posedge i_clk) begin
    if (i_rst) fpu_active <= 1'b0;
    else if (any_valid) fpu_active <= 1'b0;
    else if (start_any) fpu_active <= 1'b1;
  end

  assign o_stall = (fpu_active | (i_valid & is_fp_op_for_stall)) & ~any_valid;

  // ===========================================================================
  // In-Flight Destination Register Outputs
  // ===========================================================================
  // For RAW hazard detection: expose destinations of in-flight operations.
  // Since multi-cycle ops stall the pipeline, there's only one in-flight
  // destination at a time for each unit type.
  // In-flight destinations for RAW hazard detection
  // These go to 0 when the operation is complete (busy goes low) so hazards clear.
  // The next instruction should use forwarding from MA.
  assign o_inflight_dest_1 = adder_busy ? dest_reg_adder : 5'b0;
  assign o_inflight_dest_2 = multiplier_busy ? dest_reg_multiplier : 5'b0;
  assign o_inflight_dest_3 = fma_busy ? dest_reg_fma : 5'b0;
  assign o_inflight_dest_4 = compare_busy ? dest_reg_compare : 5'b0;
  assign o_inflight_dest_5 = convert_busy ? dest_reg_convert : 5'b0;
  logic seq_inflight;
  // Drop sequential inflight hazard when the result is valid so EX->MA can capture it.
  assign seq_inflight = dest_reg_seq_valid & ~(divider_valid | sqrt_valid);
  assign o_inflight_dest_6 = seq_inflight ? dest_reg_seq : 5'b0;

endmodule : fpu
