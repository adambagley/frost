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
  IEEE 754 single-precision floating-point divider.

  Implements FDIV.S operation using a sequential radix-2 restoring division algorithm.

  Latency: 34 cycles (not pipelined, stalls pipeline during operation)
    - 1 cycle: Input capture (IDLE)
    - 1 cycle: Operand unpacking and LZC (UNPACK)
    - 1 cycle: Mantissa normalization and special case detection (INIT)
    - 1 cycle: Division initialization (SETUP)
    - 26 cycles: Mantissa division (1 integer bit + 26 fractional/guard bits)
    - 1 cycle: Normalization
    - 1 cycle: Subnormal handling, compute round-up decision
    - 1 cycle: Apply rounding increment, format result
    - 1 cycle: Output registered result

  The UNPACK/INIT/SETUP pipeline stages split the operand processing to reduce
  combinational depth and improve timing (reduces net delay from wide datapath).

  Special case handling:
    - NaN propagation
    - Divide by zero (returns infinity, raises DZ flag)
    - 0/0 = NaN (invalid)
    - inf/inf = NaN (invalid)
    - x/0 = infinity (for finite non-zero x)
    - 0/x = 0 (for finite non-zero x)
*/
module fp_divider (
    input  logic                        i_clk,
    input  logic                        i_rst,
    input  logic                        i_valid,
    input  logic                 [31:0] i_operand_a,      // Dividend
    input  logic                 [31:0] i_operand_b,      // Divisor
    input  logic                 [ 2:0] i_rounding_mode,
    output logic                 [31:0] o_result,
    output logic                        o_valid,
    output logic                        o_stall,          // Stall pipeline during division
    output riscv_pkg::fp_flags_t        o_flags
);

  // State machine - expanded for pipelined SETUP
  typedef enum logic [3:0] {
    IDLE,
    UNPACK,
    INIT,
    SETUP,
    DIVIDE,
    NORMALIZE,
    ROUND_PREP,
    ROUND_APPLY,
    OUTPUT,
    DONE
  } state_t;

  state_t state, next_state;
  logic [ 4:0] cycle_count;

  // Registered inputs
  logic [31:0] operand_a_reg;
  logic [31:0] operand_b_reg;

  // =========================================================================
  // UNPACK Stage: Classification and LZC (combinational from operand_*_reg)
  // =========================================================================

  logic sign_a, sign_b;
  logic [7:0] exp_a, exp_b;
  logic [4:0] mant_lzc_a, mant_lzc_b;
  logic mant_lzc_found_a, mant_lzc_found_b;
  logic is_subnormal_a, is_subnormal_b;
  logic is_zero_a, is_zero_b;
  logic is_inf_a, is_inf_b;
  logic is_nan_a, is_nan_b;
  logic is_snan_a, is_snan_b;

  always_comb begin
    sign_a = operand_a_reg[31];
    sign_b = operand_b_reg[31];
    exp_a = operand_a_reg[30:23];
    exp_b = operand_b_reg[30:23];

    // Leading zero count for subnormal normalization
    mant_lzc_a = 5'd0;
    mant_lzc_b = 5'd0;
    mant_lzc_found_a = 1'b0;
    mant_lzc_found_b = 1'b0;

    // LZC for operand A
    if (exp_a == 8'b0 && operand_a_reg[22:0] != 23'b0) begin
      for (int i = 22; i >= 0; i--) begin
        if (!mant_lzc_found_a) begin
          if (operand_a_reg[i]) mant_lzc_found_a = 1'b1;
          else mant_lzc_a = mant_lzc_a + 1'b1;
        end
      end
    end

    // LZC for operand B
    if (exp_b == 8'b0 && operand_b_reg[22:0] != 23'b0) begin
      for (int i = 22; i >= 0; i--) begin
        if (!mant_lzc_found_b) begin
          if (operand_b_reg[i]) mant_lzc_found_b = 1'b1;
          else mant_lzc_b = mant_lzc_b + 1'b1;
        end
      end
    end

    // Classification
    is_subnormal_a = (exp_a == 8'b0) && (operand_a_reg[22:0] != 23'b0);
    is_subnormal_b = (exp_b == 8'b0) && (operand_b_reg[22:0] != 23'b0);
    is_zero_a = (exp_a == 8'b0) && (operand_a_reg[22:0] == 23'b0);
    is_zero_b = (exp_b == 8'b0) && (operand_b_reg[22:0] == 23'b0);
    is_inf_a = (exp_a == 8'hFF) && (operand_a_reg[22:0] == 23'b0);
    is_inf_b = (exp_b == 8'hFF) && (operand_b_reg[22:0] == 23'b0);
    is_nan_a = (exp_a == 8'hFF) && (operand_a_reg[22:0] != 23'b0);
    is_nan_b = (exp_b == 8'hFF) && (operand_b_reg[22:0] != 23'b0);
    is_snan_a = is_nan_a && ~operand_a_reg[22];
    is_snan_b = is_nan_b && ~operand_b_reg[22];
  end

  // =========================================================================
  // UNPACK -> INIT Pipeline Registers
  // =========================================================================

  logic sign_a_r, sign_b_r;
  logic [7:0] exp_a_r, exp_b_r;
  logic [4:0] mant_lzc_a_r, mant_lzc_b_r;
  logic is_subnormal_a_r, is_subnormal_b_r;
  logic is_zero_a_r, is_zero_b_r;
  logic is_inf_a_r, is_inf_b_r;
  logic is_nan_a_r, is_nan_b_r;
  logic is_snan_a_r, is_snan_b_r;
  logic [22:0] raw_mant_a_r, raw_mant_b_r;

  // =========================================================================
  // INIT Stage: Mantissa Normalization and Special Case Detection
  // Uses registered values from UNPACK stage
  // =========================================================================

  logic [5:0] sub_shift_a, sub_shift_b;
  logic signed [9:0] exp_a_adj, exp_b_adj;
  logic [23:0] mant_a, mant_b;
  logic is_special_init;
  logic [31:0] special_result_init;
  logic special_invalid_init;
  logic special_div_zero_init;

  always_comb begin
    sub_shift_a = 6'd0;
    sub_shift_b = 6'd0;
    exp_a_adj = 10'sd0;
    exp_b_adj = 10'sd0;
    mant_a = 24'b0;
    mant_b = 24'b0;

    // Operand A normalization using registered LZC
    if (is_subnormal_a_r) begin
      sub_shift_a = {1'b0, mant_lzc_a_r} + 6'd1;
      exp_a_adj = 10'sd1 - $signed({4'b0, sub_shift_a});
      mant_a = {1'b0, raw_mant_a_r} << sub_shift_a;
    end else if (exp_a_r == 8'b0) begin
      // Zero
      exp_a_adj = 10'sd0;
      mant_a = 24'b0;
    end else begin
      // Normal
      exp_a_adj = $signed({2'b0, exp_a_r});
      mant_a = {1'b1, raw_mant_a_r};
    end

    // Operand B normalization using registered LZC
    if (is_subnormal_b_r) begin
      sub_shift_b = {1'b0, mant_lzc_b_r} + 6'd1;
      exp_b_adj = 10'sd1 - $signed({4'b0, sub_shift_b});
      mant_b = {1'b0, raw_mant_b_r} << sub_shift_b;
    end else if (exp_b_r == 8'b0) begin
      // Zero
      exp_b_adj = 10'sd0;
      mant_b = 24'b0;
    end else begin
      // Normal
      exp_b_adj = $signed({2'b0, exp_b_r});
      mant_b = {1'b1, raw_mant_b_r};
    end

    // Special case detection using registered classification flags
    is_special_init = 1'b0;
    special_result_init = 32'b0;
    special_invalid_init = 1'b0;
    special_div_zero_init = 1'b0;

    if (is_nan_a_r || is_nan_b_r) begin
      is_special_init = 1'b1;
      special_result_init = riscv_pkg::FpCanonicalNan;
      special_invalid_init = is_snan_a_r | is_snan_b_r;
    end else if (is_inf_a_r && is_inf_b_r) begin
      // inf / inf = NaN
      is_special_init = 1'b1;
      special_result_init = riscv_pkg::FpCanonicalNan;
      special_invalid_init = 1'b1;
    end else if (is_zero_a_r && is_zero_b_r) begin
      // 0 / 0 = NaN
      is_special_init = 1'b1;
      special_result_init = riscv_pkg::FpCanonicalNan;
      special_invalid_init = 1'b1;
    end else if (is_inf_a_r) begin
      // inf / x = inf
      is_special_init = 1'b1;
      special_result_init = {sign_a_r ^ sign_b_r, 8'hFF, 23'b0};
    end else if (is_inf_b_r) begin
      // x / inf = 0
      is_special_init = 1'b1;
      special_result_init = {sign_a_r ^ sign_b_r, 31'b0};
    end else if (is_zero_b_r) begin
      // x / 0 = inf (divide by zero)
      is_special_init = 1'b1;
      special_result_init = {sign_a_r ^ sign_b_r, 8'hFF, 23'b0};
      special_div_zero_init = ~is_zero_a_r;
    end else if (is_zero_a_r) begin
      // 0 / x = 0
      is_special_init = 1'b1;
      special_result_init = {sign_a_r ^ sign_b_r, 31'b0};
    end
  end

  // =========================================================================
  // INIT -> SETUP Pipeline Registers
  // =========================================================================

  logic result_sign_r;
  logic signed [9:0] exp_a_adj_r, exp_b_adj_r;
  logic [23:0] mant_a_r, mant_b_r;
  logic               is_special_r;
  logic        [31:0] special_result_r;
  logic               special_invalid_r;
  logic               special_div_zero_r;

  // =========================================================================
  // Division state
  // =========================================================================

  logic signed [ 9:0] result_exp;
  logic        [26:0] quotient;  // 24 bits + 3 guard bits
  logic        [26:0] remainder;
  logic        [26:0] divisor;

  // Rounding mode storage
  logic        [ 2:0] rm;

  // Rounding inputs
  logic        [24:0] div_pre_round_mant;
  logic               div_guard_bit;
  logic               div_round_bit;
  logic               div_sticky_bit;
  logic               div_is_zero;

  assign div_pre_round_mant = quotient[26:2];
  assign div_guard_bit = quotient[1];
  assign div_round_bit = quotient[0];
  assign div_sticky_bit = |remainder;
  assign div_is_zero = (quotient == 27'b0) && (remainder == 27'b0);

  // =========================================================================
  // ROUND_PREP: Subnormal handling and round-up decision (split rounding)
  // =========================================================================

  // Extract mantissa and rounding bits
  logic [23:0] mantissa_retained_prep;
  assign mantissa_retained_prep = div_pre_round_mant[24:1];

  // Subnormal handling: compute shift and apply
  logic [23:0] mantissa_work_prep;
  logic guard_work_prep, round_work_prep, sticky_work_prep;
  logic signed [9:0] exp_work_prep;
  logic [26:0] mantissa_ext_prep, shifted_ext_prep;
  logic               shifted_sticky_prep;
  logic        [ 5:0] shift_amt_prep;
  logic signed [10:0] shift_amt_signed_prep;

  always_comb begin
    mantissa_work_prep = mantissa_retained_prep;
    guard_work_prep = div_pre_round_mant[0];
    round_work_prep = div_guard_bit;
    sticky_work_prep = div_round_bit | div_sticky_bit;
    exp_work_prep = result_exp;
    mantissa_ext_prep = {
      mantissa_retained_prep, div_pre_round_mant[0], div_guard_bit, div_round_bit | div_sticky_bit
    };
    shifted_ext_prep = mantissa_ext_prep;
    shifted_sticky_prep = 1'b0;
    shift_amt_prep = 6'd0;
    shift_amt_signed_prep = 11'sb0;

    if (result_exp <= 0) begin
      shift_amt_signed_prep = 11'sd1 - $signed({result_exp[9], result_exp});
      if (shift_amt_signed_prep >= 27) shift_amt_prep = 6'd27;
      else shift_amt_prep = shift_amt_signed_prep[5:0];
      if (shift_amt_prep >= 6'd27) begin
        shifted_ext_prep = 27'b0;
        shifted_sticky_prep = |mantissa_ext_prep;
      end else if (shift_amt_prep != 0) begin
        shifted_ext_prep = mantissa_ext_prep >> shift_amt_prep;
        shifted_sticky_prep = 1'b0;
        for (int i = 0; i < 27; i++) begin
          if (i < shift_amt_prep) shifted_sticky_prep = shifted_sticky_prep | mantissa_ext_prep[i];
        end
      end
      mantissa_work_prep = shifted_ext_prep[26:3];
      guard_work_prep = shifted_ext_prep[2];
      round_work_prep = shifted_ext_prep[1];
      sticky_work_prep = shifted_ext_prep[0] | shifted_sticky_prep;
      exp_work_prep = 10'sd0;
    end
  end

  // Compute round-up decision
  logic round_up_prep;
  logic lsb_prep;

  assign lsb_prep = mantissa_work_prep[0];

  always_comb begin
    unique case (rm)
      riscv_pkg::FRM_RNE:
      round_up_prep = guard_work_prep & (round_work_prep | sticky_work_prep | lsb_prep);
      riscv_pkg::FRM_RTZ: round_up_prep = 1'b0;
      riscv_pkg::FRM_RDN:
      round_up_prep = result_sign_r & (guard_work_prep | round_work_prep | sticky_work_prep);
      riscv_pkg::FRM_RUP:
      round_up_prep = ~result_sign_r & (guard_work_prep | round_work_prep | sticky_work_prep);
      riscv_pkg::FRM_RMM: round_up_prep = guard_work_prep;
      default: round_up_prep = guard_work_prep & (round_work_prep | sticky_work_prep | lsb_prep);
    endcase
  end

  // Compute is_inexact for flags
  logic is_inexact_prep;
  assign is_inexact_prep = guard_work_prep | round_work_prep | sticky_work_prep;

  // =========================================================================
  // ROUND_PREP -> ROUND_APPLY Pipeline Registers
  // =========================================================================

  logic               result_sign_apply;
  logic signed [ 9:0] exp_work_apply;
  logic        [23:0] mantissa_work_apply;
  logic               round_up_apply;
  logic               is_inexact_apply;
  logic               div_is_zero_apply;
  logic        [ 2:0] rm_apply;

  // =========================================================================
  // ROUND_APPLY: Apply rounding and format result
  // =========================================================================

  logic        [24:0] rounded_mantissa_apply;
  logic               mantissa_overflow_apply;
  logic signed [ 9:0] adjusted_exponent_apply;
  logic        [22:0] final_mantissa_apply;
  logic is_overflow_apply, is_underflow_apply;

  assign rounded_mantissa_apply  = {1'b0, mantissa_work_apply} + {24'b0, round_up_apply};
  assign mantissa_overflow_apply = rounded_mantissa_apply[24];

  always_comb begin
    if (mantissa_overflow_apply) begin
      if (exp_work_apply == 10'sd0) begin
        adjusted_exponent_apply = 10'sd1;
      end else begin
        adjusted_exponent_apply = exp_work_apply + 1;
      end
      final_mantissa_apply = rounded_mantissa_apply[23:1];
    end else begin
      adjusted_exponent_apply = exp_work_apply;
      final_mantissa_apply = rounded_mantissa_apply[22:0];
    end
  end

  assign is_overflow_apply  = (adjusted_exponent_apply >= 10'sd255);
  assign is_underflow_apply = (adjusted_exponent_apply <= 10'sd0);

  // Compute final result
  logic [31:0] final_result_apply_comb;
  riscv_pkg::fp_flags_t final_flags_apply_comb;

  always_comb begin
    final_result_apply_comb = 32'b0;
    final_flags_apply_comb  = '0;

    if (div_is_zero_apply) begin
      final_result_apply_comb = {result_sign_apply, 31'b0};
    end else if (is_overflow_apply) begin
      final_flags_apply_comb.of = 1'b1;
      final_flags_apply_comb.nx = 1'b1;
      if ((rm_apply == riscv_pkg::FRM_RTZ) ||
          (rm_apply == riscv_pkg::FRM_RDN && !result_sign_apply) ||
          (rm_apply == riscv_pkg::FRM_RUP && result_sign_apply)) begin
        final_result_apply_comb = {result_sign_apply, 8'hFE, 23'h7FFFFF};
      end else begin
        final_result_apply_comb = {result_sign_apply, 8'hFF, 23'b0};
      end
    end else if (is_underflow_apply) begin
      final_flags_apply_comb.uf = is_inexact_apply;
      final_flags_apply_comb.nx = is_inexact_apply;
      final_result_apply_comb   = {result_sign_apply, 8'b0, final_mantissa_apply};
    end else begin
      final_flags_apply_comb.nx = is_inexact_apply;
      final_result_apply_comb = {
        result_sign_apply, adjusted_exponent_apply[7:0], final_mantissa_apply
      };
    end
  end

  // =========================================================================
  // ROUND_APPLY -> OUTPUT Pipeline Registers
  // =========================================================================

  logic [31:0] result_output;
  riscv_pkg::fp_flags_t flags_output;

  // =========================================================================
  // State Machine
  // =========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      IDLE: begin
        if (i_valid) begin
          next_state = UNPACK;
        end
      end
      UNPACK: begin
        next_state = INIT;
      end
      INIT: begin
        // Always go to SETUP - is_special_r will be valid there
        next_state = SETUP;
      end
      SETUP: begin
        // is_special_r is now valid (registered in INIT)
        if (is_special_r) begin
          next_state = DONE;
        end else begin
          next_state = DIVIDE;
        end
      end
      DIVIDE: begin
        if (cycle_count == 5'd25) begin
          next_state = NORMALIZE;
        end
      end
      NORMALIZE: begin
        next_state = ROUND_PREP;
      end
      ROUND_PREP: begin
        next_state = ROUND_APPLY;
      end
      ROUND_APPLY: begin
        next_state = OUTPUT;
      end
      OUTPUT: begin
        next_state = DONE;
      end
      DONE: begin
        next_state = IDLE;
      end
      default: next_state = IDLE;
    endcase
  end

  // =========================================================================
  // Division Logic
  // =========================================================================

  logic [26:0] next_quotient;
  logic [26:0] next_remainder;
  logic [26:0] shifted_remainder;
  logic [26:0] diff;
  logic        diff_neg;
  logic [ 5:0] quotient_lzc;
  logic        quotient_lzc_found;
  logic        quotient_is_zero;

  always_comb begin
    shifted_remainder = {remainder[25:0], 1'b0};
    diff = shifted_remainder - divisor;
    diff_neg = diff[26];

    if (diff_neg) begin
      // Remainder < divisor: quotient bit is 0
      next_remainder = shifted_remainder;
      next_quotient  = {quotient[25:0], 1'b0};
    end else begin
      // Remainder >= divisor: quotient bit is 1
      next_remainder = diff;
      next_quotient  = {quotient[25:0], 1'b1};
    end
  end

  // Leading-zero count for quotient normalization
  always_comb begin
    quotient_lzc = 6'd0;
    quotient_lzc_found = 1'b0;
    quotient_is_zero = (quotient == 27'b0);

    if (!quotient_is_zero) begin
      for (int i = 26; i >= 0; i--) begin
        if (!quotient_lzc_found) begin
          if (quotient[i]) quotient_lzc_found = 1'b1;
          else quotient_lzc = quotient_lzc + 1'b1;
        end
      end
    end
  end

  // =========================================================================
  // Main Datapath
  // =========================================================================

  logic [31:0] result_reg;
  riscv_pkg::fp_flags_t flags_reg;
  logic valid_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      cycle_count <= 5'd0;
      quotient <= 27'b0;
      remainder <= 27'b0;
      divisor <= 27'b0;
      result_exp <= 10'sb0;
      rm <= 3'b0;
      operand_a_reg <= 32'b0;
      operand_b_reg <= 32'b0;
      // UNPACK -> INIT registers
      sign_a_r <= 1'b0;
      sign_b_r <= 1'b0;
      exp_a_r <= 8'b0;
      exp_b_r <= 8'b0;
      mant_lzc_a_r <= 5'b0;
      mant_lzc_b_r <= 5'b0;
      is_subnormal_a_r <= 1'b0;
      is_subnormal_b_r <= 1'b0;
      is_zero_a_r <= 1'b0;
      is_zero_b_r <= 1'b0;
      is_inf_a_r <= 1'b0;
      is_inf_b_r <= 1'b0;
      is_nan_a_r <= 1'b0;
      is_nan_b_r <= 1'b0;
      is_snan_a_r <= 1'b0;
      is_snan_b_r <= 1'b0;
      raw_mant_a_r <= 23'b0;
      raw_mant_b_r <= 23'b0;
      // INIT -> SETUP registers
      result_sign_r <= 1'b0;
      exp_a_adj_r <= 10'sb0;
      exp_b_adj_r <= 10'sb0;
      mant_a_r <= 24'b0;
      mant_b_r <= 24'b0;
      is_special_r <= 1'b0;
      special_result_r <= 32'b0;
      special_invalid_r <= 1'b0;
      special_div_zero_r <= 1'b0;
      // ROUND_PREP -> ROUND_APPLY registers
      result_sign_apply <= 1'b0;
      exp_work_apply <= 10'sb0;
      mantissa_work_apply <= 24'b0;
      round_up_apply <= 1'b0;
      is_inexact_apply <= 1'b0;
      div_is_zero_apply <= 1'b0;
      rm_apply <= 3'b0;
      // ROUND_APPLY -> OUTPUT registers
      result_output <= 32'b0;
      flags_output <= '0;
      // Final output
      result_reg <= 32'b0;
      flags_reg <= '0;
      valid_reg <= 1'b0;
    end else begin
      valid_reg <= 1'b0;

      case (state)
        IDLE: begin
          if (i_valid) begin
            operand_a_reg <= i_operand_a;
            operand_b_reg <= i_operand_b;
            rm <= i_rounding_mode;
            cycle_count <= 5'd0;
          end
        end

        UNPACK: begin
          // Register operand classification and LZC results
          sign_a_r <= sign_a;
          sign_b_r <= sign_b;
          exp_a_r <= exp_a;
          exp_b_r <= exp_b;
          mant_lzc_a_r <= mant_lzc_a;
          mant_lzc_b_r <= mant_lzc_b;
          is_subnormal_a_r <= is_subnormal_a;
          is_subnormal_b_r <= is_subnormal_b;
          is_zero_a_r <= is_zero_a;
          is_zero_b_r <= is_zero_b;
          is_inf_a_r <= is_inf_a;
          is_inf_b_r <= is_inf_b;
          is_nan_a_r <= is_nan_a;
          is_nan_b_r <= is_nan_b;
          is_snan_a_r <= is_snan_a;
          is_snan_b_r <= is_snan_b;
          raw_mant_a_r <= operand_a_reg[22:0];
          raw_mant_b_r <= operand_b_reg[22:0];
        end

        INIT: begin
          // Register normalized mantissas and special case detection
          result_sign_r <= sign_a_r ^ sign_b_r;
          exp_a_adj_r <= exp_a_adj;
          exp_b_adj_r <= exp_b_adj;
          mant_a_r <= mant_a;
          mant_b_r <= mant_b;
          is_special_r <= is_special_init;
          special_result_r <= special_result_init;
          special_invalid_r <= special_invalid_init;
          special_div_zero_r <= special_div_zero_init;
        end

        SETUP: begin
          // Use registered values from INIT stage
          if (is_special_r) begin
            result_reg <= special_result_r;
            flags_reg  <= {special_invalid_r, special_div_zero_r, 1'b0, 1'b0, 1'b0};
          end else begin
            // Initialize division using registered mantissas
            // exp_result = exp_a - exp_b + 127
            result_exp <= exp_a_adj_r - exp_b_adj_r + 10'sd127;
            divisor <= {3'b0, mant_b_r};
            if (mant_a_r >= mant_b_r) begin
              quotient  <= 27'd1;
              remainder <= {3'b0, mant_a_r - mant_b_r};
            end else begin
              quotient  <= 27'b0;
              remainder <= {3'b0, mant_a_r};
            end
          end
        end

        DIVIDE: begin
          cycle_count <= cycle_count + 1'b1;
          quotient <= next_quotient;
          remainder <= next_remainder;
        end

        NORMALIZE: begin
          if (!quotient_is_zero && quotient_lzc != 0) begin
            quotient   <= quotient << quotient_lzc;
            result_exp <= result_exp - $signed({4'b0, quotient_lzc});
          end
          // quotient[26] is now the implicit 1 (unless result is zero)
        end

        ROUND_PREP: begin
          // Capture round-up decision into apply registers
          result_sign_apply <= result_sign_r;
          exp_work_apply <= exp_work_prep;
          mantissa_work_apply <= mantissa_work_prep;
          round_up_apply <= round_up_prep;
          is_inexact_apply <= is_inexact_prep;
          div_is_zero_apply <= div_is_zero;
          rm_apply <= rm;
        end

        ROUND_APPLY: begin
          // Capture final result into output registers
          result_output <= final_result_apply_comb;
          flags_output  <= final_flags_apply_comb;
        end

        OUTPUT: begin
          // Capture into final result registers
          result_reg <= result_output;
          flags_reg  <= flags_output;
        end

        DONE: begin
          valid_reg <= 1'b1;
        end

        default: ;
      endcase
    end
  end

  // =========================================================================
  // Outputs
  // =========================================================================

  assign o_result = result_reg;
  assign o_flags  = flags_reg;
  assign o_valid  = valid_reg;
  // Stall immediately when i_valid is asserted (FDIV enters EX), matching integer
  // divider pattern where stall = (is_divide & ~divider_valid_output). The integer
  // stall is true from the first cycle because valid_output starts at 0. We achieve
  // the same by OR'ing i_valid with the state check, so stall is asserted on the
  // same cycle the instruction enters EX. Stall drops when valid_reg goes high.
  assign o_stall  = ((state != IDLE) || i_valid) && ~valid_reg;

endmodule : fp_divider
