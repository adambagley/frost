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
  IEEE 754 single-precision fused multiply-add.

  This implementation computes (a * b) + c with a single rounding step.
  It handles NaNs, infinities, zeros, and subnormal operands.

  Operations:
    FMADD.S:  fd = (fs1 * fs2) + fs3
    FMSUB.S:  fd = (fs1 * fs2) - fs3
    FNMADD.S: fd = -(fs1 * fs2) - fs3
    FNMSUB.S: fd = -(fs1 * fs2) + fs3

  Multi-cycle implementation (12-cycle latency, non-pipelined):
    Cycle 0: Capture operands
    Cycle 1: Unpack operands, detect special cases
    Cycle 2: Multiply mantissas (24x24 -> 48 bits)
    Cycle 3A: Product LZC computation
    Cycle 3B: Normalize product (apply shift)
    Cycle 4: Align exponent/shift amount prep
    Cycle 5: Align product and addend (barrel shift)
    Cycle 6: Add/subtract, LZC
    Cycle 7: Normalize based on LZC
    Cycle 8: Subnormal handling, compute round-up decision
    Cycle 9: Apply rounding increment, format result
    Cycle 10: Output registered result
*/
module fp_fma (
    input  logic                        i_clk,
    input  logic                        i_rst,
    input  logic                        i_valid,
    input  logic                 [31:0] i_operand_a,
    input  logic                 [31:0] i_operand_b,
    input  logic                 [31:0] i_operand_c,
    input  logic                        i_negate_product,
    input  logic                        i_negate_c,
    input  logic                 [ 2:0] i_rounding_mode,
    input  logic                        i_stall,
    output logic                 [31:0] o_result,
    output logic                        o_valid,
    output riscv_pkg::fp_flags_t        o_flags
);

  typedef enum logic [3:0] {
    IDLE    = 4'b0000,
    STAGE1  = 4'b0001,
    STAGE2  = 4'b0010,
    STAGE3A = 4'b0011,
    STAGE3B = 4'b0100,
    STAGE4  = 4'b0101,
    STAGE4B = 4'b0110,
    STAGE5  = 4'b0111,
    STAGE6  = 4'b1000,
    STAGE7  = 4'b1001,
    STAGE8  = 4'b1010,
    STAGE9  = 4'b1011
  } state_e;

  state_e state, next_state;

  // Input registers
  logic [31:0] operand_a_reg;
  logic [31:0] operand_b_reg;
  logic [31:0] operand_c_reg;
  logic        negate_product_reg;
  logic        negate_c_reg;
  logic [ 2:0] rm_reg;

  // =========================================================================
  // Stage 1: Unpack operands (combinational from registered inputs)
  // =========================================================================

  logic sign_a, sign_b, sign_c;
  logic [7:0] exp_a, exp_b, exp_c;
  logic [22:0] mant_a, mant_b, mant_c;
  logic is_zero_a, is_zero_b, is_zero_c;
  logic is_inf_a, is_inf_b, is_inf_c;
  logic is_nan_a, is_nan_b, is_nan_c;
  logic is_snan_a, is_snan_b, is_snan_c;
  logic [7:0] exp_a_adj, exp_b_adj, exp_c_adj;
  logic [23:0] mant_a_int, mant_b_int, mant_c_int;

  assign sign_a = operand_a_reg[31];
  assign sign_b = operand_b_reg[31];
  assign sign_c = operand_c_reg[31];
  assign exp_a = operand_a_reg[30:23];
  assign exp_b = operand_b_reg[30:23];
  assign exp_c = operand_c_reg[30:23];
  assign mant_a = operand_a_reg[22:0];
  assign mant_b = operand_b_reg[22:0];
  assign mant_c = operand_c_reg[22:0];

  assign is_zero_a = (exp_a == 8'h00) && (mant_a == 23'b0);
  assign is_zero_b = (exp_b == 8'h00) && (mant_b == 23'b0);
  assign is_zero_c = (exp_c == 8'h00) && (mant_c == 23'b0);
  assign is_inf_a = (exp_a == 8'hFF) && (mant_a == 23'b0);
  assign is_inf_b = (exp_b == 8'hFF) && (mant_b == 23'b0);
  assign is_inf_c = (exp_c == 8'hFF) && (mant_c == 23'b0);
  assign is_nan_a = (exp_a == 8'hFF) && (mant_a != 23'b0);
  assign is_nan_b = (exp_b == 8'hFF) && (mant_b != 23'b0);
  assign is_nan_c = (exp_c == 8'hFF) && (mant_c != 23'b0);
  assign is_snan_a = is_nan_a && ~mant_a[22];
  assign is_snan_b = is_nan_b && ~mant_b[22];
  assign is_snan_c = is_nan_c && ~mant_c[22];

  assign exp_a_adj = (exp_a == 8'h00 && mant_a != 23'b0) ? 8'd1 : exp_a;
  assign exp_b_adj = (exp_b == 8'h00 && mant_b != 23'b0) ? 8'd1 : exp_b;
  assign exp_c_adj = (exp_c == 8'h00 && mant_c != 23'b0) ? 8'd1 : exp_c;
  assign mant_a_int = (exp_a == 8'h00) ? {1'b0, mant_a} : {1'b1, mant_a};
  assign mant_b_int = (exp_b == 8'h00) ? {1'b0, mant_b} : {1'b1, mant_b};
  assign mant_c_int = (exp_c == 8'h00) ? {1'b0, mant_c} : {1'b1, mant_c};

  // Sign control for FMA variants
  logic sign_prod;
  logic sign_c_adj;
  assign sign_prod  = sign_a ^ sign_b ^ negate_product_reg;
  assign sign_c_adj = sign_c ^ negate_c_reg;

  // Special case detection
  logic        is_special;
  logic [31:0] special_result;
  logic        special_invalid;

  always_comb begin
    is_special = 1'b0;
    special_result = 32'b0;
    special_invalid = 1'b0;

    if (is_nan_a || is_nan_b || is_nan_c) begin
      is_special = 1'b1;
      special_result = riscv_pkg::FpCanonicalNan;
      special_invalid = is_snan_a | is_snan_b | is_snan_c;
    end else if ((is_inf_a && is_zero_b) || (is_zero_a && is_inf_b)) begin
      is_special = 1'b1;
      special_result = riscv_pkg::FpCanonicalNan;
      special_invalid = 1'b1;
    end else if (is_inf_a || is_inf_b) begin
      if (is_inf_c && (sign_c_adj != sign_prod)) begin
        is_special = 1'b1;
        special_result = riscv_pkg::FpCanonicalNan;
        special_invalid = 1'b1;
      end else begin
        is_special = 1'b1;
        special_result = {sign_prod, 8'hFF, 23'b0};
      end
    end else if (is_inf_c) begin
      is_special = 1'b1;
      special_result = {sign_c_adj, 8'hFF, 23'b0};
    end
  end

  // Product exponent
  logic signed [9:0] prod_exp_tentative;
  assign prod_exp_tentative = $signed({2'b0, exp_a_adj}) + $signed({2'b0, exp_b_adj}) - 10'sd127;

  // =========================================================================
  // Stage 1 -> Stage 2 Pipeline Registers (after unpack, before multiply)
  // =========================================================================

  logic [23:0] mant_a_s2, mant_b_s2;
  logic signed [ 9:0] prod_exp_s2;
  logic               prod_sign_s2;
  logic signed [ 9:0] c_exp_s2;
  logic        [23:0] mant_c_s2;
  logic               c_sign_s2;
  logic        [ 2:0] rm_s2;
  logic               is_special_s2;
  logic        [31:0] special_result_s2;
  logic               special_invalid_s2;

  // =========================================================================
  // Stage 2: Multiply (combinational 24x24 from stage 2 regs)
  // Use DSP48 blocks to reduce LUT congestion
  // =========================================================================

  (* use_dsp = "yes" *)
  logic        [47:0] prod_mant_s2_comb;
  assign prod_mant_s2_comb = mant_a_s2 * mant_b_s2;

  // =========================================================================
  // Stage 2 -> Stage 3 Pipeline Registers (after multiply, before normalize)
  // =========================================================================

  logic        [47:0] prod_mant_s3;
  logic signed [ 9:0] prod_exp_s3;
  logic               prod_sign_s3;
  logic signed [ 9:0] c_exp_s3;
  logic        [23:0] mant_c_s3;
  logic               c_sign_s3;
  logic        [ 2:0] rm_s3;
  logic               is_special_s3;
  logic        [31:0] special_result_s3;
  logic               special_invalid_s3;

  // =========================================================================
  // Stage 3A: Product LZC (combinational from stage 3 regs)
  // =========================================================================

  logic        [ 5:0] prod_lzc;
  logic               prod_lzc_found;
  logic               prod_is_zero;
  logic               prod_msb_set;

  assign prod_is_zero = (prod_mant_s3 == 48'b0);
  assign prod_msb_set = prod_mant_s3[47];

  always_comb begin
    prod_lzc = 6'd0;
    prod_lzc_found = 1'b0;
    if (!prod_is_zero && !prod_msb_set) begin
      for (int i = 46; i >= 0; i--) begin
        if (!prod_lzc_found) begin
          if (prod_mant_s3[i]) begin
            prod_lzc_found = 1'b1;
          end else begin
            prod_lzc = prod_lzc + 1;
          end
        end
      end
    end
  end

  // =========================================================================
  // Stage 3A -> Stage 3B Pipeline Registers (after LZC, before shift)
  // =========================================================================

  logic        [47:0] prod_mant_s3b;
  logic signed [ 9:0] prod_exp_s3b;
  logic               prod_sign_s3b;
  logic               prod_is_zero_s3b;
  logic               prod_msb_set_s3b;
  logic        [ 5:0] prod_lzc_s3b;
  logic signed [ 9:0] c_exp_s3b;
  logic        [23:0] mant_c_s3b;
  logic               c_sign_s3b;
  logic        [ 2:0] rm_s3b;
  logic               is_special_s3b;
  logic        [31:0] special_result_s3b;
  logic               special_invalid_s3b;

  // =========================================================================
  // Stage 3B: Apply Normalization Shift (combinational from stage 3B regs)
  // =========================================================================

  logic signed [ 9:0] prod_exp_norm;
  logic        [47:0] prod_mant_norm;

  always_comb begin
    if (prod_is_zero_s3b) begin
      prod_mant_norm = 48'b0;
      prod_exp_norm  = 10'sb0;
    end else if (prod_msb_set_s3b) begin
      prod_mant_norm = prod_mant_s3b;
      prod_exp_norm  = prod_exp_s3b + 1;
    end else begin
      prod_mant_norm = prod_mant_s3b << (prod_lzc_s3b + 1'b1);
      prod_exp_norm  = prod_exp_s3b - $signed({4'b0, prod_lzc_s3b});
    end
  end

  // =========================================================================
  // Stage 3B -> Stage 4 Pipeline Registers (after prod norm, before align)
  // =========================================================================

  logic signed [ 9:0] prod_exp_s4;
  logic        [47:0] prod_mant_s4;
  logic               prod_sign_s4;
  logic signed [ 9:0] c_exp_s4;
  logic        [47:0] c_mant_s4;
  logic               c_sign_s4;
  logic        [ 2:0] rm_s4;
  logic               is_special_s4;
  logic        [31:0] special_result_s4;
  logic               special_invalid_s4;

  // =========================================================================
  // Stage 4: Align prep (exponent compare + shift amount)
  // =========================================================================

  logic signed [ 9:0] exp_large;
  logic        [ 6:0] shift_prod_amt;
  logic        [ 6:0] shift_c_amt;
  logic signed [10:0] shift_prod_signed;
  logic signed [10:0] shift_c_signed;

  always_comb begin
    exp_large = (prod_exp_s4 >= c_exp_s4) ? prod_exp_s4 : c_exp_s4;

    shift_prod_signed = $signed({exp_large[9], exp_large}) - $signed({prod_exp_s4[9], prod_exp_s4});
    shift_c_signed = $signed({exp_large[9], exp_large}) - $signed({c_exp_s4[9], c_exp_s4});

    if (shift_prod_signed < 0) shift_prod_amt = 7'd0;
    else if (shift_prod_signed >= 48) shift_prod_amt = 7'd48;
    else shift_prod_amt = shift_prod_signed[6:0];

    if (shift_c_signed < 0) shift_c_amt = 7'd0;
    else if (shift_c_signed >= 48) shift_c_amt = 7'd48;
    else shift_c_amt = shift_c_signed[6:0];
  end

  // =========================================================================
  // Stage 4 -> Stage 4b Pipeline Registers (after shift amount calc)
  // =========================================================================

  logic signed [ 9:0] exp_large_s4b;
  logic        [ 6:0] shift_prod_amt_s4b;
  logic        [ 6:0] shift_c_amt_s4b;

  // =========================================================================
  // Stage 4b: Align (barrel shift - combinational from stage 4 regs)
  // =========================================================================

  logic        [47:0] prod_aligned;
  logic        [47:0] c_aligned;
  logic               sticky_prod;
  logic               sticky_c;

  always_comb begin
    prod_aligned = prod_mant_s4;
    sticky_prod  = 1'b0;
    if (shift_prod_amt_s4b >= 7'd48) begin
      prod_aligned = 48'b0;
      sticky_prod  = |prod_mant_s4;
    end else if (shift_prod_amt_s4b != 0) begin
      prod_aligned = prod_mant_s4 >> shift_prod_amt_s4b;
      sticky_prod  = 1'b0;
      for (int i = 0; i < 48; i++) begin
        if (i < shift_prod_amt_s4b) sticky_prod = sticky_prod | prod_mant_s4[i];
      end
    end

    c_aligned = c_mant_s4;
    sticky_c  = 1'b0;
    if (shift_c_amt_s4b >= 7'd48) begin
      c_aligned = 48'b0;
      sticky_c  = |c_mant_s4;
    end else if (shift_c_amt_s4b != 0) begin
      c_aligned = c_mant_s4 >> shift_c_amt_s4b;
      sticky_c  = 1'b0;
      for (int i = 0; i < 48; i++) begin
        if (i < shift_c_amt_s4b) sticky_c = sticky_c | c_mant_s4[i];
      end
    end
  end

  // =========================================================================
  // Stage 4b -> Stage 5 Pipeline Registers (after align, before add)
  // =========================================================================

  logic signed [ 9:0] exp_large_s5;
  logic        [47:0] prod_aligned_s5;
  logic        [47:0] c_aligned_s5;
  logic               prod_sign_s5;
  logic               c_sign_s5;
  logic               sticky_s5;
  logic               sticky_c_sub_s5;  // Sticky from addend shifted out during subtraction
  logic        [ 2:0] rm_s5;
  logic               is_special_s5;
  logic        [31:0] special_result_s5;
  logic               special_invalid_s5;

  // =========================================================================
  // Stage 5: Add/Subtract and LZC (combinational from stage 5 regs)
  // =========================================================================

  logic        [48:0] sum_s5_comb;
  logic               result_sign_s5_comb;
  logic               sign_large_s5_comb;
  logic               sign_small_s5_comb;
  logic               sum_is_zero_s5_comb;

  always_comb begin
    if (prod_sign_s5 == c_sign_s5) begin
      sum_s5_comb = {1'b0, prod_aligned_s5} + {1'b0, c_aligned_s5};
      result_sign_s5_comb = prod_sign_s5;
      sign_large_s5_comb = prod_sign_s5;
      sign_small_s5_comb = c_sign_s5;
    end else begin
      if (prod_aligned_s5 > c_aligned_s5) begin
        sum_s5_comb = {1'b0, prod_aligned_s5} - {1'b0, c_aligned_s5};
        result_sign_s5_comb = prod_sign_s5;
        sign_large_s5_comb = prod_sign_s5;
        sign_small_s5_comb = c_sign_s5;
      end else if (c_aligned_s5 > prod_aligned_s5) begin
        sum_s5_comb = {1'b0, c_aligned_s5} - {1'b0, prod_aligned_s5};
        result_sign_s5_comb = c_sign_s5;
        sign_large_s5_comb = c_sign_s5;
        sign_small_s5_comb = prod_sign_s5;
      end else begin
        sum_s5_comb = 49'b0;
        result_sign_s5_comb = prod_sign_s5;
        sign_large_s5_comb = prod_sign_s5;
        sign_small_s5_comb = c_sign_s5;
      end
    end
    sum_is_zero_s5_comb = (sum_s5_comb == 49'b0);
  end

  // LZC for sum - tree-based implementation for better timing
  // Uses clz49 from riscv_pkg which has O(log n) depth instead of O(n)
  logic [5:0] lzc_s5_comb;

  assign lzc_s5_comb = sum_is_zero_s5_comb ? 6'd0 : riscv_pkg::clz49(sum_s5_comb);

  // =========================================================================
  // Stage 5 -> Stage 6 Pipeline Registers (after add/LZC, before normalize)
  // =========================================================================

  logic signed [ 9:0] exp_large_s6;
  logic        [48:0] sum_s6;
  logic               sum_is_zero_s6;
  logic        [ 5:0] lzc_s6;
  logic               sum_sticky_s6;
  logic               sticky_c_sub_s6;  // Sticky from addend shifted out during subtraction
  logic               result_sign_s6;
  logic               sign_large_s6;
  logic               sign_small_s6;
  logic        [ 2:0] rm_s6;
  logic               is_special_s6;
  logic        [31:0] special_result_s6;
  logic               special_invalid_s6;

  // =========================================================================
  // Stage 6: Normalize (combinational from stage 6 regs)
  // =========================================================================

  logic        [ 5:0] norm_shift;
  logic        [48:0] normalized_sum_s6_comb;
  logic signed [ 9:0] normalized_exp_s6_comb;
  logic               norm_sticky_s6_comb;  // Sticky bit from normalization right-shift

  assign norm_shift = (lzc_s6 > 6'd1) ? (lzc_s6 - 6'd1) : 6'd0;

  always_comb begin
    norm_sticky_s6_comb = 1'b0;
    if (sum_is_zero_s6) begin
      normalized_sum_s6_comb = 49'b0;
      normalized_exp_s6_comb = 10'sb0;
    end else if (sum_s6[48]) begin
      normalized_sum_s6_comb = sum_s6 >> 1;
      normalized_exp_s6_comb = exp_large_s6 + 1;
      // Capture the bit shifted out - it contributes to sticky for rounding
      norm_sticky_s6_comb = sum_s6[0];
    end else if (lzc_s6 > 1) begin
      normalized_sum_s6_comb = sum_s6 << norm_shift;
      normalized_exp_s6_comb = exp_large_s6 - $signed({4'b0, norm_shift});
    end else begin
      normalized_sum_s6_comb = sum_s6;
      normalized_exp_s6_comb = exp_large_s6;
    end
  end

  // =========================================================================
  // Stage 6 -> Stage 7 Pipeline Registers (after normalize, before round)
  // =========================================================================

  logic        [48:0] normalized_sum_s7;
  logic signed [ 9:0] normalized_exp_s7;
  logic               sum_is_zero_s7;
  logic               sum_sticky_s7;
  logic               sticky_c_sub_s7;  // Sticky from addend shifted out during subtraction
  logic               norm_sticky_s7;  // Sticky from normalization right-shift
  logic               result_sign_s7;
  logic               sign_large_s7;
  logic               sign_small_s7;
  logic        [ 2:0] rm_s7;
  logic               is_special_s7;
  logic        [31:0] special_result_s7;
  logic               special_invalid_s7;

  // =========================================================================
  // Stage 7: Round (combinational from stage 7 regs)
  // =========================================================================
  // Stage 7: Prepare rounding inputs and compute round-up decision
  // (Split rounding into 2 stages to meet timing)
  // =========================================================================

  logic        [24:0] pre_round_mant_s7;
  logic               final_sticky_s7;
  logic               fp_round_sign_s7;

  assign pre_round_mant_s7 = normalized_sum_s7[47:23];
  assign final_sticky_s7   = |normalized_sum_s7[20:0] | sum_sticky_s7 | norm_sticky_s7;

  always_comb begin
    fp_round_sign_s7 = result_sign_s7;
    if (sum_is_zero_s7 && !sum_sticky_s7) begin
      if (sign_large_s7 != sign_small_s7)
        fp_round_sign_s7 = (rm_s7 == riscv_pkg::FRM_RDN) ? 1'b1 : 1'b0;
      else fp_round_sign_s7 = sign_large_s7;
    end
  end

  // Extract mantissa and rounding bits
  logic [23:0] mantissa_retained_s7;
  logic guard_bit_s7, round_bit_s7, sticky_bit_s7;
  logic guard_bit_raw_s7;

  assign mantissa_retained_s7 = pre_round_mant_s7[24:1];
  assign guard_bit_raw_s7 = pre_round_mant_s7[0];
  // When the addend was shifted out during subtraction AND guard=1 AND bits[22:0]=0,
  // the exact result is just below the boundary, so guard should be 0.
  // This handles the FMA precision case where subtracting a small value causes
  // a borrow that flips the guard bit.
  assign guard_bit_s7 = guard_bit_raw_s7 & ~(sticky_c_sub_s7 & (normalized_sum_s7[22:0] == 23'b0));
  assign round_bit_s7 = normalized_sum_s7[22];
  assign sticky_bit_s7 = normalized_sum_s7[21] | final_sticky_s7;

  // Subnormal handling: compute shift and apply
  logic [23:0] mantissa_work_s7;
  logic guard_work_s7, round_work_s7, sticky_work_s7;
  logic signed [9:0] exp_work_s7;
  logic [26:0] mantissa_ext_s7, shifted_ext_s7;
  logic               shifted_sticky_s7;
  logic        [ 5:0] shift_amt_s7;
  logic signed [10:0] shift_amt_signed_s7;

  always_comb begin
    mantissa_work_s7 = mantissa_retained_s7;
    guard_work_s7 = guard_bit_s7;
    round_work_s7 = round_bit_s7;
    sticky_work_s7 = sticky_bit_s7;
    exp_work_s7 = normalized_exp_s7;
    mantissa_ext_s7 = {mantissa_retained_s7, guard_bit_s7, round_bit_s7, sticky_bit_s7};
    shifted_ext_s7 = mantissa_ext_s7;
    shifted_sticky_s7 = 1'b0;
    shift_amt_s7 = 6'd0;
    shift_amt_signed_s7 = 11'sb0;

    if (normalized_exp_s7 <= 0) begin
      shift_amt_signed_s7 = 11'sd1 - $signed({normalized_exp_s7[9], normalized_exp_s7});
      if (shift_amt_signed_s7 >= 27) shift_amt_s7 = 6'd27;
      else shift_amt_s7 = shift_amt_signed_s7[5:0];
      if (shift_amt_s7 >= 6'd27) begin
        shifted_ext_s7 = 27'b0;
        shifted_sticky_s7 = |mantissa_ext_s7;
      end else if (shift_amt_s7 != 0) begin
        shifted_ext_s7 = mantissa_ext_s7 >> shift_amt_s7;
        shifted_sticky_s7 = 1'b0;
        for (int i = 0; i < 27; i++) begin
          if (i < shift_amt_s7) shifted_sticky_s7 = shifted_sticky_s7 | mantissa_ext_s7[i];
        end
      end
      mantissa_work_s7 = shifted_ext_s7[26:3];
      guard_work_s7 = shifted_ext_s7[2];
      round_work_s7 = shifted_ext_s7[1];
      sticky_work_s7 = shifted_ext_s7[0] | shifted_sticky_s7;
      exp_work_s7 = 10'sd0;
    end
  end

  // Compute round-up decision
  logic round_up_s7;
  logic lsb_s7;

  assign lsb_s7 = mantissa_work_s7[0];

  always_comb begin
    unique case (rm_s7)
      riscv_pkg::FRM_RNE: round_up_s7 = guard_work_s7 & (round_work_s7 | sticky_work_s7 | lsb_s7);
      riscv_pkg::FRM_RTZ: round_up_s7 = 1'b0;
      riscv_pkg::FRM_RDN:
      round_up_s7 = fp_round_sign_s7 & (guard_work_s7 | round_work_s7 | sticky_work_s7);
      riscv_pkg::FRM_RUP:
      round_up_s7 = ~fp_round_sign_s7 & (guard_work_s7 | round_work_s7 | sticky_work_s7);
      riscv_pkg::FRM_RMM: round_up_s7 = guard_work_s7;
      default: round_up_s7 = guard_work_s7 & (round_work_s7 | sticky_work_s7 | lsb_s7);
    endcase
  end

  // Compute is_inexact for flags
  logic is_inexact_s7;
  logic is_zero_result_s7;
  assign is_inexact_s7 = guard_work_s7 | round_work_s7 | sticky_work_s7;
  assign is_zero_result_s7 = sum_is_zero_s7 && !sum_sticky_s7;

  // =========================================================================
  // Stage 7 -> Stage 8 Pipeline Register (after round-up decision)
  // =========================================================================

  logic               result_sign_s8;
  logic signed [ 9:0] exp_work_s8;
  logic        [23:0] mantissa_work_s8;
  logic               round_up_s8;
  logic               is_inexact_s8;
  logic               is_zero_result_s8;
  logic        [ 2:0] rm_s8;
  logic               is_special_s8;
  logic        [31:0] special_result_s8;
  logic               special_invalid_s8;

  // =========================================================================
  // Stage 8: Apply rounding and format result (combinational from s8 regs)
  // =========================================================================

  logic        [24:0] rounded_mantissa_s8;
  logic               mantissa_overflow_s8;
  logic signed [ 9:0] adjusted_exponent_s8;
  logic        [22:0] final_mantissa_s8;
  logic is_overflow_s8, is_underflow_s8;

  assign rounded_mantissa_s8  = {1'b0, mantissa_work_s8} + {24'b0, round_up_s8};
  assign mantissa_overflow_s8 = rounded_mantissa_s8[24];

  always_comb begin
    if (mantissa_overflow_s8) begin
      if (exp_work_s8 == 10'sd0) begin
        adjusted_exponent_s8 = 10'sd1;
      end else begin
        adjusted_exponent_s8 = exp_work_s8 + 1;
      end
      final_mantissa_s8 = rounded_mantissa_s8[23:1];
    end else begin
      adjusted_exponent_s8 = exp_work_s8;
      final_mantissa_s8 = rounded_mantissa_s8[22:0];
    end
  end

  assign is_overflow_s8  = (adjusted_exponent_s8 >= 10'sd255);
  assign is_underflow_s8 = (adjusted_exponent_s8 <= 10'sd0);

  // Compute final result
  logic [31:0] final_result_s8_comb;
  riscv_pkg::fp_flags_t final_flags_s8_comb;

  always_comb begin
    final_result_s8_comb = 32'b0;
    final_flags_s8_comb  = '0;

    if (is_special_s8) begin
      final_result_s8_comb   = special_result_s8;
      final_flags_s8_comb.nv = special_invalid_s8;
    end else if (is_zero_result_s8) begin
      final_result_s8_comb = {result_sign_s8, 31'b0};
    end else if (is_overflow_s8) begin
      final_flags_s8_comb.of = 1'b1;
      final_flags_s8_comb.nx = 1'b1;
      if ((rm_s8 == riscv_pkg::FRM_RTZ) ||
          (rm_s8 == riscv_pkg::FRM_RDN && !result_sign_s8) ||
          (rm_s8 == riscv_pkg::FRM_RUP && result_sign_s8)) begin
        final_result_s8_comb = {result_sign_s8, 8'hFE, 23'h7FFFFF};
      end else begin
        final_result_s8_comb = {result_sign_s8, 8'hFF, 23'b0};
      end
    end else if (is_underflow_s8) begin
      final_flags_s8_comb.uf = is_inexact_s8;
      final_flags_s8_comb.nx = is_inexact_s8;
      final_result_s8_comb   = {result_sign_s8, 8'b0, final_mantissa_s8};
    end else begin
      final_flags_s8_comb.nx = is_inexact_s8;
      final_result_s8_comb   = {result_sign_s8, adjusted_exponent_s8[7:0], final_mantissa_s8};
    end
  end

  // =========================================================================
  // Stage 8 -> Stage 9 Pipeline Register (final output)
  // =========================================================================

  logic [31:0] result_s9;
  riscv_pkg::fp_flags_t flags_s9;

  // =========================================================================
  // State Machine and Sequential Logic
  // =========================================================================

  logic valid_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      operand_a_reg <= 32'b0;
      operand_b_reg <= 32'b0;
      operand_c_reg <= 32'b0;
      negate_product_reg <= 1'b0;
      negate_c_reg <= 1'b0;
      rm_reg <= 3'b0;
      // Stage 2
      mant_a_s2 <= 24'b0;
      mant_b_s2 <= 24'b0;
      prod_exp_s2 <= 10'sb0;
      prod_sign_s2 <= 1'b0;
      c_exp_s2 <= 10'sb0;
      mant_c_s2 <= 24'b0;
      c_sign_s2 <= 1'b0;
      rm_s2 <= 3'b0;
      is_special_s2 <= 1'b0;
      special_result_s2 <= 32'b0;
      special_invalid_s2 <= 1'b0;
      // Stage 3 (before LZC)
      prod_mant_s3 <= 48'b0;
      prod_exp_s3 <= 10'sb0;
      prod_sign_s3 <= 1'b0;
      c_exp_s3 <= 10'sb0;
      mant_c_s3 <= 24'b0;
      c_sign_s3 <= 1'b0;
      rm_s3 <= 3'b0;
      is_special_s3 <= 1'b0;
      special_result_s3 <= 32'b0;
      special_invalid_s3 <= 1'b0;
      // Stage 3B (after LZC, before shift)
      prod_mant_s3b <= 48'b0;
      prod_exp_s3b <= 10'sb0;
      prod_sign_s3b <= 1'b0;
      prod_is_zero_s3b <= 1'b0;
      prod_msb_set_s3b <= 1'b0;
      prod_lzc_s3b <= 6'b0;
      c_exp_s3b <= 10'sb0;
      mant_c_s3b <= 24'b0;
      c_sign_s3b <= 1'b0;
      rm_s3b <= 3'b0;
      is_special_s3b <= 1'b0;
      special_result_s3b <= 32'b0;
      special_invalid_s3b <= 1'b0;
      // Stage 4
      prod_exp_s4 <= 10'sb0;
      prod_mant_s4 <= 48'b0;
      prod_sign_s4 <= 1'b0;
      c_exp_s4 <= 10'sb0;
      c_mant_s4 <= 48'b0;
      c_sign_s4 <= 1'b0;
      rm_s4 <= 3'b0;
      is_special_s4 <= 1'b0;
      special_result_s4 <= 32'b0;
      special_invalid_s4 <= 1'b0;
      // Stage 4b
      exp_large_s4b <= 10'sb0;
      shift_prod_amt_s4b <= 7'b0;
      shift_c_amt_s4b <= 7'b0;
      // Stage 5
      exp_large_s5 <= 10'sb0;
      prod_aligned_s5 <= 48'b0;
      c_aligned_s5 <= 48'b0;
      prod_sign_s5 <= 1'b0;
      c_sign_s5 <= 1'b0;
      sticky_s5 <= 1'b0;
      sticky_c_sub_s5 <= 1'b0;
      rm_s5 <= 3'b0;
      is_special_s5 <= 1'b0;
      special_result_s5 <= 32'b0;
      special_invalid_s5 <= 1'b0;
      // Stage 6
      exp_large_s6 <= 10'sb0;
      sum_s6 <= 49'b0;
      sum_is_zero_s6 <= 1'b0;
      lzc_s6 <= 6'b0;
      sum_sticky_s6 <= 1'b0;
      sticky_c_sub_s6 <= 1'b0;
      result_sign_s6 <= 1'b0;
      sign_large_s6 <= 1'b0;
      sign_small_s6 <= 1'b0;
      rm_s6 <= 3'b0;
      is_special_s6 <= 1'b0;
      special_result_s6 <= 32'b0;
      special_invalid_s6 <= 1'b0;
      // Stage 7
      normalized_sum_s7 <= 49'b0;
      normalized_exp_s7 <= 10'sb0;
      sum_is_zero_s7 <= 1'b0;
      sum_sticky_s7 <= 1'b0;
      sticky_c_sub_s7 <= 1'b0;
      norm_sticky_s7 <= 1'b0;
      result_sign_s7 <= 1'b0;
      sign_large_s7 <= 1'b0;
      sign_small_s7 <= 1'b0;
      rm_s7 <= 3'b0;
      is_special_s7 <= 1'b0;
      special_result_s7 <= 32'b0;
      special_invalid_s7 <= 1'b0;
      // Stage 8 (after round-up decision)
      result_sign_s8 <= 1'b0;
      exp_work_s8 <= 10'sb0;
      mantissa_work_s8 <= 24'b0;
      round_up_s8 <= 1'b0;
      is_inexact_s8 <= 1'b0;
      is_zero_result_s8 <= 1'b0;
      rm_s8 <= 3'b0;
      is_special_s8 <= 1'b0;
      special_result_s8 <= 32'b0;
      special_invalid_s8 <= 1'b0;
      // Stage 9 (final output)
      result_s9 <= 32'b0;
      flags_s9 <= '0;
      valid_reg <= 1'b0;
    end else begin
      state <= next_state;
      valid_reg <= (state == STAGE9);

      case (state)
        IDLE: begin
          if (i_valid) begin
            operand_a_reg <= i_operand_a;
            operand_b_reg <= i_operand_b;
            operand_c_reg <= i_operand_c;
            negate_product_reg <= i_negate_product;
            negate_c_reg <= i_negate_c;
            rm_reg <= i_rounding_mode;
          end
        end

        STAGE1: begin
          mant_a_s2 <= mant_a_int;
          mant_b_s2 <= mant_b_int;
          prod_exp_s2 <= prod_exp_tentative;
          prod_sign_s2 <= sign_prod;
          c_exp_s2 <= $signed({2'b0, exp_c_adj});
          mant_c_s2 <= mant_c_int;
          c_sign_s2 <= sign_c_adj;
          rm_s2 <= rm_reg;
          is_special_s2 <= is_special;
          special_result_s2 <= special_result;
          special_invalid_s2 <= special_invalid;
        end

        STAGE2: begin
          prod_mant_s3 <= prod_mant_s2_comb;
          prod_exp_s3 <= prod_exp_s2;
          prod_sign_s3 <= prod_sign_s2;
          c_exp_s3 <= c_exp_s2;
          mant_c_s3 <= mant_c_s2;
          c_sign_s3 <= c_sign_s2;
          rm_s3 <= rm_s2;
          is_special_s3 <= is_special_s2;
          special_result_s3 <= special_result_s2;
          special_invalid_s3 <= special_invalid_s2;
        end

        STAGE3A: begin
          // Capture LZC results into stage 3B registers
          prod_mant_s3b <= prod_mant_s3;
          prod_exp_s3b <= prod_exp_s3;
          prod_sign_s3b <= prod_sign_s3;
          prod_is_zero_s3b <= prod_is_zero;
          prod_msb_set_s3b <= prod_msb_set;
          prod_lzc_s3b <= prod_lzc;
          c_exp_s3b <= c_exp_s3;
          mant_c_s3b <= mant_c_s3;
          c_sign_s3b <= c_sign_s3;
          rm_s3b <= rm_s3;
          is_special_s3b <= is_special_s3;
          special_result_s3b <= special_result_s3;
          special_invalid_s3b <= special_invalid_s3;
        end

        STAGE3B: begin
          // Capture normalized product into stage 4 registers
          prod_exp_s4 <= prod_exp_norm;
          prod_mant_s4 <= prod_mant_norm;
          prod_sign_s4 <= prod_sign_s3b;
          c_exp_s4 <= c_exp_s3b;
          c_mant_s4 <= {mant_c_s3b, 24'b0};
          c_sign_s4 <= c_sign_s3b;
          rm_s4 <= rm_s3b;
          is_special_s4 <= is_special_s3b;
          special_result_s4 <= special_result_s3b;
          special_invalid_s4 <= special_invalid_s3b;
        end

        STAGE4: begin
          exp_large_s4b <= exp_large;
          shift_prod_amt_s4b <= shift_prod_amt;
          shift_c_amt_s4b <= shift_c_amt;
        end

        STAGE4B: begin
          exp_large_s5 <= exp_large_s4b;
          prod_aligned_s5 <= prod_aligned;
          c_aligned_s5 <= c_aligned;
          prod_sign_s5 <= prod_sign_s4;
          c_sign_s5 <= c_sign_s4;
          sticky_s5 <= sticky_prod | sticky_c;
          // Track when addend was shifted out during subtraction (product larger)
          // This affects the guard bit calculation for FMA precision
          sticky_c_sub_s5 <= sticky_c & (prod_sign_s4 != c_sign_s4) & (prod_aligned > c_aligned);
          rm_s5 <= rm_s4;
          is_special_s5 <= is_special_s4;
          special_result_s5 <= special_result_s4;
          special_invalid_s5 <= special_invalid_s4;
        end

        STAGE5: begin
          exp_large_s6 <= exp_large_s5;
          sum_s6 <= sum_s5_comb;
          sum_is_zero_s6 <= sum_is_zero_s5_comb;
          lzc_s6 <= lzc_s5_comb;
          sum_sticky_s6 <= sticky_s5;
          sticky_c_sub_s6 <= sticky_c_sub_s5;
          result_sign_s6 <= result_sign_s5_comb;
          sign_large_s6 <= sign_large_s5_comb;
          sign_small_s6 <= sign_small_s5_comb;
          rm_s6 <= rm_s5;
          is_special_s6 <= is_special_s5;
          special_result_s6 <= special_result_s5;
          special_invalid_s6 <= special_invalid_s5;
        end

        STAGE6: begin
          normalized_sum_s7 <= normalized_sum_s6_comb;
          normalized_exp_s7 <= normalized_exp_s6_comb;
          sum_is_zero_s7 <= sum_is_zero_s6;
          sum_sticky_s7 <= sum_sticky_s6;
          sticky_c_sub_s7 <= sticky_c_sub_s6;
          norm_sticky_s7 <= norm_sticky_s6_comb;
          result_sign_s7 <= result_sign_s6;
          sign_large_s7 <= sign_large_s6;
          sign_small_s7 <= sign_small_s6;
          rm_s7 <= rm_s6;
          is_special_s7 <= is_special_s6;
          special_result_s7 <= special_result_s6;
          special_invalid_s7 <= special_invalid_s6;
        end

        STAGE7: begin
          // Capture round-up decision into s8 registers
          result_sign_s8 <= fp_round_sign_s7;
          exp_work_s8 <= exp_work_s7;
          mantissa_work_s8 <= mantissa_work_s7;
          round_up_s8 <= round_up_s7;
          is_inexact_s8 <= is_inexact_s7;
          is_zero_result_s8 <= is_zero_result_s7;
          rm_s8 <= rm_s7;
          is_special_s8 <= is_special_s7;
          special_result_s8 <= special_result_s7;
          special_invalid_s8 <= special_invalid_s7;
        end

        STAGE8: begin
          // Capture final result into s9 registers
          result_s9 <= final_result_s8_comb;
          flags_s9  <= final_flags_s8_comb;
        end

        STAGE9: begin
          // Output already captured in s9
        end

        default: ;
      endcase
    end
  end

  // Next state logic
  always_comb begin
    next_state = state;
    case (state)
      IDLE:    if (i_valid) next_state = STAGE1;
      STAGE1:  next_state = STAGE2;
      STAGE2:  next_state = STAGE3A;
      STAGE3A: next_state = STAGE3B;
      STAGE3B: next_state = STAGE4;
      STAGE4:  next_state = STAGE4B;
      STAGE4B: next_state = STAGE5;
      STAGE5:  next_state = STAGE6;
      STAGE6:  next_state = STAGE7;
      STAGE7:  next_state = STAGE8;
      STAGE8:  next_state = STAGE9;
      STAGE9:  next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  // Output logic (from registered s9)
  assign o_result = result_s9;
  assign o_flags  = flags_s9;
  assign o_valid  = valid_reg;

endmodule : fp_fma
