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
  IEEE 754 single-precision floating-point multiplier.

  Implements FMUL.S operation.

  Multi-cycle implementation (8-cycle latency, non-pipelined):
    Cycle 0: Capture operands
    Cycle 1: Unpack, compute result sign and exponent, detect special cases
    Cycle 2: Multiply mantissas (24x24 -> 48 bits)
    Cycle 3A: Compute leading zero count (LZC)
    Cycle 3B: Apply normalization shift
    Cycle 4: Subnormal handling, compute round-up decision
    Cycle 5: Apply rounding increment, format result
    Cycle 6: Capture result
    Cycle 7: Output registered result

  This non-pipelined design stalls the CPU for the full duration
  of the operation, ensuring operand stability without complex capture bypass.

  Special case handling:
    - NaN propagation (quiet NaN result)
    - Infinity * 0 = NaN (invalid)
    - Infinity * finite = infinity
    - Zero * anything = zero (with proper sign)
*/
module fp_multiplier (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [31:0] i_operand_a,
    input logic [31:0] i_operand_b,
    input logic [2:0] i_rounding_mode,
    input logic i_stall,  // Pipeline stall (unused in non-pipelined mode)
    output logic [31:0] o_result,
    output logic o_valid,
    output riscv_pkg::fp_flags_t o_flags
);

  // =========================================================================
  // State Machine
  // =========================================================================

  typedef enum logic [2:0] {
    IDLE    = 3'b000,
    STAGE1  = 3'b001,
    STAGE2  = 3'b010,
    STAGE3A = 3'b011,
    STAGE3B = 3'b100,
    STAGE4  = 3'b101,
    STAGE5  = 3'b110,
    STAGE6  = 3'b111
  } state_e;

  state_e state, next_state;

  // =========================================================================
  // Captured Operands (registered at start of operation)
  // =========================================================================

  logic [31:0] operand_a_reg, operand_b_reg;
  logic [2:0] rounding_mode_reg;

  // =========================================================================
  // Stage 1: Unpack (combinational from captured operands)
  // =========================================================================

  logic [31:0] op_a, op_b;
  assign op_a = operand_a_reg;
  assign op_b = operand_b_reg;

  logic sign_a, sign_b, result_sign;
  logic [7:0] exp_a, exp_b;
  logic [7:0] exp_a_adj, exp_b_adj;
  logic [23:0] mant_a, mant_b;

  assign sign_a = op_a[31];
  assign sign_b = op_b[31];
  assign result_sign = sign_a ^ sign_b;

  assign exp_a = op_a[30:23];
  assign exp_b = op_b[30:23];
  assign exp_a_adj = (exp_a == 8'b0 && op_a[22:0] != 23'b0) ? 8'd1 : exp_a;
  assign exp_b_adj = (exp_b == 8'b0 && op_b[22:0] != 23'b0) ? 8'd1 : exp_b;

  // Mantissa with implicit 1 (or 0 for zero/subnormal)
  assign mant_a = (exp_a == 8'b0) ? {1'b0, op_a[22:0]} : {1'b1, op_a[22:0]};
  assign mant_b = (exp_b == 8'b0) ? {1'b0, op_b[22:0]} : {1'b1, op_b[22:0]};

  // Special value detection
  logic is_zero_a, is_zero_b;
  logic is_inf_a, is_inf_b;
  logic is_nan_a, is_nan_b;
  logic is_snan_a, is_snan_b;

  assign is_zero_a = (exp_a == 8'b0) && (op_a[22:0] == 23'b0);
  assign is_zero_b = (exp_b == 8'b0) && (op_b[22:0] == 23'b0);
  assign is_inf_a  = (exp_a == 8'hFF) && (op_a[22:0] == 23'b0);
  assign is_inf_b  = (exp_b == 8'hFF) && (op_b[22:0] == 23'b0);
  assign is_nan_a  = (exp_a == 8'hFF) && (op_a[22:0] != 23'b0);
  assign is_nan_b  = (exp_b == 8'hFF) && (op_b[22:0] != 23'b0);
  assign is_snan_a = is_nan_a && ~op_a[22];
  assign is_snan_b = is_nan_b && ~op_b[22];

  // Compute tentative exponent (before normalization)
  logic signed [9:0] tentative_exp;
  assign tentative_exp = $signed({2'b0, exp_a_adj}) + $signed({2'b0, exp_b_adj}) - 10'sd127;

  // Special case handling
  logic        is_special;
  logic [31:0] special_result;
  logic        special_invalid;

  always_comb begin
    is_special = 1'b0;
    special_result = 32'b0;
    special_invalid = 1'b0;

    if (is_nan_a || is_nan_b) begin
      is_special = 1'b1;
      special_result = riscv_pkg::FpCanonicalNan;
      special_invalid = is_snan_a | is_snan_b;
    end else if ((is_inf_a && is_zero_b) || (is_zero_a && is_inf_b)) begin
      is_special = 1'b1;
      special_result = riscv_pkg::FpCanonicalNan;
      special_invalid = 1'b1;
    end else if (is_inf_a || is_inf_b) begin
      is_special = 1'b1;
      special_result = {result_sign, 8'hFF, 23'b0};
    end else if (is_zero_a || is_zero_b) begin
      is_special = 1'b1;
      special_result = {result_sign, 31'b0};
    end
  end

  // =========================================================================
  // Stage 1 -> Stage 2 Pipeline Register (after unpack, before multiply)
  // =========================================================================

  logic              result_sign_s2;
  logic signed [9:0] tentative_exp_s2;
  logic [23:0] mant_a_s2, mant_b_s2;
  logic        is_special_s2;
  logic [31:0] special_result_s2;
  logic        special_invalid_s2;
  logic [ 2:0] rm_s2;

  // =========================================================================
  // Stage 2: Multiply (combinational 24x24 from stage 2 regs)
  // Use DSP48 blocks to reduce LUT congestion
  // =========================================================================

  (* use_dsp = "yes" *)
  logic [47:0] product_s2_comb;
  assign product_s2_comb = mant_a_s2 * mant_b_s2;

  // =========================================================================
  // Stage 2 -> Stage 3 Pipeline Register (after multiply, before normalize)
  // =========================================================================

  logic               result_sign_s3;
  logic signed [ 9:0] tentative_exp_s3;
  logic        [47:0] product_s3;
  logic               is_special_s3;
  logic        [31:0] special_result_s3;
  logic               special_invalid_s3;
  logic        [ 2:0] rm_s3;

  // =========================================================================
  // Stage 3A: Compute Leading Zero Count (combinational from stage 3 regs)
  // =========================================================================

  logic               product_is_zero_s3;
  logic               product_msb_set_s3;

  assign product_is_zero_s3 = (product_s3 == 48'b0);
  assign product_msb_set_s3 = product_s3[47];

  logic [5:0] lzc_s3;
  logic       lzc_found_s3;

  always_comb begin
    lzc_s3 = 6'd0;
    lzc_found_s3 = 1'b0;
    if (!product_is_zero_s3 && !product_msb_set_s3) begin
      for (int i = 46; i >= 0; i--) begin
        if (!lzc_found_s3) begin
          if (product_s3[i]) begin
            lzc_found_s3 = 1'b1;
          end else begin
            lzc_s3 = lzc_s3 + 1;
          end
        end
      end
    end
  end

  // =========================================================================
  // Stage 3A -> Stage 3B Pipeline Register (after LZC, before shift)
  // =========================================================================

  logic               result_sign_s3b;
  logic signed [ 9:0] tentative_exp_s3b;
  logic        [47:0] product_s3b;
  logic               product_is_zero_s3b;
  logic               product_msb_set_s3b;
  logic        [ 5:0] lzc_s3b;
  logic               is_special_s3b;
  logic        [31:0] special_result_s3b;
  logic               special_invalid_s3b;
  logic        [ 2:0] rm_s3b;

  // =========================================================================
  // Stage 3B: Apply Normalization Shift (combinational from stage 3B regs)
  // =========================================================================

  logic        [47:0] normalized_product_s3b;
  logic signed [ 9:0] normalized_exp_s3b;

  always_comb begin
    if (product_is_zero_s3b) begin
      normalized_product_s3b = 48'b0;
      normalized_exp_s3b = 10'sb0;
    end else if (product_msb_set_s3b) begin
      normalized_product_s3b = product_s3b;
      normalized_exp_s3b = tentative_exp_s3b + 1;
    end else begin
      normalized_product_s3b = product_s3b << (lzc_s3b + 1'b1);
      normalized_exp_s3b = tentative_exp_s3b - $signed({4'b0, lzc_s3b});
    end
  end

  // =========================================================================
  // Stage 3B -> Stage 4 Pipeline Register (after normalize, before round)
  // =========================================================================

  logic               result_sign_s4;
  logic signed [ 9:0] exp_s4;
  logic        [47:0] product_s4;
  logic               product_is_zero_s4;
  logic               is_special_s4;
  logic        [31:0] special_result_s4;
  logic               special_invalid_s4;
  logic        [ 2:0] rm_s4;

  // =========================================================================
  // Stage 4: Subnormal handling, compute round-up decision
  // (Split rounding into 2 stages to meet timing)
  // =========================================================================

  logic        [24:0] pre_round_mant_s4;
  logic guard_bit_s4, round_bit_s4, sticky_bit_s4;

  assign pre_round_mant_s4 = product_s4[47:23];
  assign guard_bit_s4 = product_s4[22];
  assign round_bit_s4 = product_s4[21];
  assign sticky_bit_s4 = |product_s4[20:0];

  // Extract mantissa and rounding bits
  logic [23:0] mantissa_retained_s4;
  assign mantissa_retained_s4 = pre_round_mant_s4[24:1];

  // Subnormal handling: compute shift and apply
  logic [23:0] mantissa_work_s4;
  logic guard_work_s4, round_work_s4, sticky_work_s4;
  logic signed [9:0] exp_work_s4;
  logic [26:0] mantissa_ext_s4, shifted_ext_s4;
  logic               shifted_sticky_s4;
  logic        [ 5:0] shift_amt_s4;
  logic signed [10:0] shift_amt_signed_s4;

  always_comb begin
    mantissa_work_s4 = mantissa_retained_s4;
    guard_work_s4 = pre_round_mant_s4[0];
    round_work_s4 = guard_bit_s4;
    sticky_work_s4 = round_bit_s4 | sticky_bit_s4;
    exp_work_s4 = exp_s4;
    mantissa_ext_s4 = {
      mantissa_retained_s4, pre_round_mant_s4[0], guard_bit_s4, round_bit_s4 | sticky_bit_s4
    };
    shifted_ext_s4 = mantissa_ext_s4;
    shifted_sticky_s4 = 1'b0;
    shift_amt_s4 = 6'd0;
    shift_amt_signed_s4 = 11'sb0;

    if (exp_s4 <= 0) begin
      shift_amt_signed_s4 = 11'sd1 - $signed({exp_s4[9], exp_s4});
      if (shift_amt_signed_s4 >= 27) shift_amt_s4 = 6'd27;
      else shift_amt_s4 = shift_amt_signed_s4[5:0];
      if (shift_amt_s4 >= 6'd27) begin
        shifted_ext_s4 = 27'b0;
        shifted_sticky_s4 = |mantissa_ext_s4;
      end else if (shift_amt_s4 != 0) begin
        shifted_ext_s4 = mantissa_ext_s4 >> shift_amt_s4;
        shifted_sticky_s4 = 1'b0;
        for (int i = 0; i < 27; i++) begin
          if (i < shift_amt_s4) shifted_sticky_s4 = shifted_sticky_s4 | mantissa_ext_s4[i];
        end
      end
      mantissa_work_s4 = shifted_ext_s4[26:3];
      guard_work_s4 = shifted_ext_s4[2];
      round_work_s4 = shifted_ext_s4[1];
      sticky_work_s4 = shifted_ext_s4[0] | shifted_sticky_s4;
      exp_work_s4 = 10'sd0;
    end
  end

  // Compute round-up decision
  logic round_up_s4;
  logic lsb_s4;

  assign lsb_s4 = mantissa_work_s4[0];

  always_comb begin
    unique case (rm_s4)
      riscv_pkg::FRM_RNE: round_up_s4 = guard_work_s4 & (round_work_s4 | sticky_work_s4 | lsb_s4);
      riscv_pkg::FRM_RTZ: round_up_s4 = 1'b0;
      riscv_pkg::FRM_RDN:
      round_up_s4 = result_sign_s4 & (guard_work_s4 | round_work_s4 | sticky_work_s4);
      riscv_pkg::FRM_RUP:
      round_up_s4 = ~result_sign_s4 & (guard_work_s4 | round_work_s4 | sticky_work_s4);
      riscv_pkg::FRM_RMM: round_up_s4 = guard_work_s4;
      default: round_up_s4 = guard_work_s4 & (round_work_s4 | sticky_work_s4 | lsb_s4);
    endcase
  end

  // Compute is_inexact for flags
  logic is_inexact_s4;
  assign is_inexact_s4 = guard_work_s4 | round_work_s4 | sticky_work_s4;

  // =========================================================================
  // Stage 4 -> Stage 5 Pipeline Register (after round-up decision)
  // =========================================================================

  logic               result_sign_s5;
  logic signed [ 9:0] exp_work_s5;
  logic        [23:0] mantissa_work_s5;
  logic               round_up_s5;
  logic               is_inexact_s5;
  logic               product_is_zero_s5;
  logic        [ 2:0] rm_s5;
  logic               is_special_s5;
  logic        [31:0] special_result_s5;
  logic               special_invalid_s5;

  // =========================================================================
  // Stage 5: Apply rounding and format result (combinational from s5 regs)
  // =========================================================================

  logic        [24:0] rounded_mantissa_s5;
  logic               mantissa_overflow_s5;
  logic signed [ 9:0] adjusted_exponent_s5;
  logic        [22:0] final_mantissa_s5;
  logic is_overflow_s5, is_underflow_s5;

  assign rounded_mantissa_s5  = {1'b0, mantissa_work_s5} + {24'b0, round_up_s5};
  assign mantissa_overflow_s5 = rounded_mantissa_s5[24];

  always_comb begin
    if (mantissa_overflow_s5) begin
      if (exp_work_s5 == 10'sd0) begin
        adjusted_exponent_s5 = 10'sd1;
      end else begin
        adjusted_exponent_s5 = exp_work_s5 + 1;
      end
      final_mantissa_s5 = rounded_mantissa_s5[23:1];
    end else begin
      adjusted_exponent_s5 = exp_work_s5;
      final_mantissa_s5 = rounded_mantissa_s5[22:0];
    end
  end

  assign is_overflow_s5  = (adjusted_exponent_s5 >= 10'sd255);
  assign is_underflow_s5 = (adjusted_exponent_s5 <= 10'sd0);

  // Compute final result
  logic [31:0] final_result_s5_comb;
  riscv_pkg::fp_flags_t final_flags_s5_comb;

  always_comb begin
    final_result_s5_comb = 32'b0;
    final_flags_s5_comb  = '0;

    if (is_special_s5) begin
      final_result_s5_comb   = special_result_s5;
      final_flags_s5_comb.nv = special_invalid_s5;
    end else if (product_is_zero_s5) begin
      final_result_s5_comb = {result_sign_s5, 31'b0};
    end else if (is_overflow_s5) begin
      final_flags_s5_comb.of = 1'b1;
      final_flags_s5_comb.nx = 1'b1;
      if ((rm_s5 == riscv_pkg::FRM_RTZ) ||
          (rm_s5 == riscv_pkg::FRM_RDN && !result_sign_s5) ||
          (rm_s5 == riscv_pkg::FRM_RUP && result_sign_s5)) begin
        final_result_s5_comb = {result_sign_s5, 8'hFE, 23'h7FFFFF};
      end else begin
        final_result_s5_comb = {result_sign_s5, 8'hFF, 23'b0};
      end
    end else if (is_underflow_s5) begin
      final_flags_s5_comb.uf = is_inexact_s5;
      final_flags_s5_comb.nx = is_inexact_s5;
      final_result_s5_comb   = {result_sign_s5, 8'b0, final_mantissa_s5};
    end else begin
      final_flags_s5_comb.nx = is_inexact_s5;
      final_result_s5_comb   = {result_sign_s5, adjusted_exponent_s5[7:0], final_mantissa_s5};
    end
  end

  // =========================================================================
  // Stage 5 -> Stage 6 Pipeline Register (final output)
  // =========================================================================

  logic [31:0] result_s6;
  riscv_pkg::fp_flags_t flags_s6;

  // =========================================================================
  // State Machine and Sequential Logic
  // =========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      operand_a_reg <= 32'b0;
      operand_b_reg <= 32'b0;
      rounding_mode_reg <= 3'b0;
      // Stage 2 registers
      result_sign_s2 <= 1'b0;
      tentative_exp_s2 <= 10'sb0;
      mant_a_s2 <= 24'b0;
      mant_b_s2 <= 24'b0;
      is_special_s2 <= 1'b0;
      special_result_s2 <= 32'b0;
      special_invalid_s2 <= 1'b0;
      rm_s2 <= 3'b0;
      // Stage 3 registers (before LZC)
      result_sign_s3 <= 1'b0;
      tentative_exp_s3 <= 10'sb0;
      product_s3 <= 48'b0;
      is_special_s3 <= 1'b0;
      special_result_s3 <= 32'b0;
      special_invalid_s3 <= 1'b0;
      rm_s3 <= 3'b0;
      // Stage 3B registers (after LZC, before shift)
      result_sign_s3b <= 1'b0;
      tentative_exp_s3b <= 10'sb0;
      product_s3b <= 48'b0;
      product_is_zero_s3b <= 1'b0;
      product_msb_set_s3b <= 1'b0;
      lzc_s3b <= 6'b0;
      is_special_s3b <= 1'b0;
      special_result_s3b <= 32'b0;
      special_invalid_s3b <= 1'b0;
      rm_s3b <= 3'b0;
      // Stage 4 registers
      result_sign_s4 <= 1'b0;
      exp_s4 <= 10'sb0;
      product_s4 <= 48'b0;
      product_is_zero_s4 <= 1'b0;
      is_special_s4 <= 1'b0;
      special_result_s4 <= 32'b0;
      special_invalid_s4 <= 1'b0;
      rm_s4 <= 3'b0;
      // Stage 5 registers (after round-up decision)
      result_sign_s5 <= 1'b0;
      exp_work_s5 <= 10'sb0;
      mantissa_work_s5 <= 24'b0;
      round_up_s5 <= 1'b0;
      is_inexact_s5 <= 1'b0;
      product_is_zero_s5 <= 1'b0;
      rm_s5 <= 3'b0;
      is_special_s5 <= 1'b0;
      special_result_s5 <= 32'b0;
      special_invalid_s5 <= 1'b0;
      // Stage 6 registers (final output)
      result_s6 <= 32'b0;
      flags_s6 <= '0;
    end else begin
      state <= next_state;

      case (state)
        IDLE: begin
          if (i_valid) begin
            // Capture operands at start of operation
            operand_a_reg <= i_operand_a;
            operand_b_reg <= i_operand_b;
            rounding_mode_reg <= i_rounding_mode;
          end
        end

        STAGE1: begin
          // Capture stage 1 results into stage 2 registers
          result_sign_s2 <= result_sign;
          tentative_exp_s2 <= tentative_exp;
          mant_a_s2 <= mant_a;
          mant_b_s2 <= mant_b;
          is_special_s2 <= is_special;
          special_result_s2 <= special_result;
          special_invalid_s2 <= special_invalid;
          rm_s2 <= rounding_mode_reg;
        end

        STAGE2: begin
          // Capture stage 2 results into stage 3 registers
          result_sign_s3 <= result_sign_s2;
          tentative_exp_s3 <= tentative_exp_s2;
          product_s3 <= product_s2_comb;
          is_special_s3 <= is_special_s2;
          special_result_s3 <= special_result_s2;
          special_invalid_s3 <= special_invalid_s2;
          rm_s3 <= rm_s2;
        end

        STAGE3A: begin
          // Capture LZC results into stage 3B registers
          result_sign_s3b <= result_sign_s3;
          tentative_exp_s3b <= tentative_exp_s3;
          product_s3b <= product_s3;
          product_is_zero_s3b <= product_is_zero_s3;
          product_msb_set_s3b <= product_msb_set_s3;
          lzc_s3b <= lzc_s3;
          is_special_s3b <= is_special_s3;
          special_result_s3b <= special_result_s3;
          special_invalid_s3b <= special_invalid_s3;
          rm_s3b <= rm_s3;
        end

        STAGE3B: begin
          // Capture stage 3B results into stage 4 registers
          result_sign_s4 <= result_sign_s3b;
          exp_s4 <= normalized_exp_s3b;
          product_s4 <= normalized_product_s3b;
          product_is_zero_s4 <= product_is_zero_s3b;
          is_special_s4 <= is_special_s3b;
          special_result_s4 <= special_result_s3b;
          special_invalid_s4 <= special_invalid_s3b;
          rm_s4 <= rm_s3b;
        end

        STAGE4: begin
          // Capture round-up decision into s5 registers
          result_sign_s5 <= result_sign_s4;
          exp_work_s5 <= exp_work_s4;
          mantissa_work_s5 <= mantissa_work_s4;
          round_up_s5 <= round_up_s4;
          is_inexact_s5 <= is_inexact_s4;
          product_is_zero_s5 <= product_is_zero_s4;
          rm_s5 <= rm_s4;
          is_special_s5 <= is_special_s4;
          special_result_s5 <= special_result_s4;
          special_invalid_s5 <= special_invalid_s4;
        end

        STAGE5: begin
          // Capture final result into s6 registers
          result_s6 <= final_result_s5_comb;
          flags_s6  <= final_flags_s5_comb;
        end

        STAGE6: begin
          // Output already captured in s6
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
      STAGE4:  next_state = STAGE5;
      STAGE5:  next_state = STAGE6;
      STAGE6:  next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  // =========================================================================
  // Output Logic
  // =========================================================================

  logic valid_reg;
  always_ff @(posedge i_clk) begin
    if (i_rst) valid_reg <= 1'b0;
    else valid_reg <= (state == STAGE6);
  end
  assign o_valid  = valid_reg;

  // Output from registered s6
  assign o_result = result_s6;
  assign o_flags  = flags_s6;

endmodule : fp_multiplier
