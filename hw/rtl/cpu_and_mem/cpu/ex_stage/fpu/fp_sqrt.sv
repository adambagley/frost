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
  IEEE 754 single-precision floating-point square root.

  Implements FSQRT.S operation using a digit-by-digit algorithm.

  Latency: 19 cycles (not pipelined, stalls pipeline during operation)
    - 1 cycle: Input capture
    - 1 cycle: Special case detection and setup
    - 12 cycles: Square root computation
    - 1 cycle: Normalization
    - 1 cycle: Subnormal handling, compute round-up decision
    - 1 cycle: Apply rounding increment, format result
    - 1 cycle: Capture result
    - 1 cycle: Output registered result

  Algorithm: Non-restoring digit recurrence
    sqrt(x) where x = 2^(2k) * m, m in [1, 4)
    Result = 2^k * sqrt(m)

  Special case handling:
    - sqrt(NaN) = NaN
    - sqrt(-x) = NaN (invalid, for x > 0)
    - sqrt(+inf) = +inf
    - sqrt(-0) = -0
    - sqrt(+0) = +0
*/
module fp_sqrt (
    input  logic                        i_clk,
    input  logic                        i_rst,
    input  logic                        i_valid,
    input  logic                 [31:0] i_operand,
    input  logic                 [ 2:0] i_rounding_mode,
    output logic                 [31:0] o_result,
    output logic                        o_valid,
    output logic                        o_stall,
    output riscv_pkg::fp_flags_t        o_flags
);

  // State machine
  typedef enum logic [2:0] {
    IDLE,
    SETUP,
    COMPUTE,
    NORMALIZE,
    ROUND_PREP,
    ROUND_APPLY,
    OUTPUT,
    DONE
  } state_t;

  state_t state, next_state;
  logic [ 4:0] cycle_count;

  // Registered input
  logic [31:0] operand_reg;

  // Operand fields
  logic        sign;
  logic [ 7:0] exp;
  logic [22:0] mant;
  logic is_zero, is_inf, is_nan, is_snan;
  logic               is_subnormal;
  logic signed [ 9:0] exp_adj;
  logic        [23:0] mant_norm;
  logic        [ 4:0] mant_lzc;
  logic        [ 5:0] sub_shift;
  logic               mant_lzc_found;

  // Special case handling
  logic               is_special;
  logic        [31:0] special_result;
  logic               special_invalid;

  // Square root state
  logic signed [ 9:0] result_exp;
  logic        [26:0] root;  // Result accumulator
  logic        [55:0] remainder;  // For digit computation
  logic        [53:0] radicand;  // Mantissa bits consumed 2 at a time

  // Rounding mode storage
  logic        [ 2:0] rm;
  logic               result_sign;
  logic signed [ 9:0] sqrt_unbiased_exp;
  logic               sqrt_exp_is_even;
  logic signed [10:0] sqrt_adjusted_exp;
  logic        [24:0] sqrt_mantissa_int;
  logic        [ 5:0] sqrt_shift_amount;

  // Rounding inputs
  logic        [24:0] sqrt_pre_round_mant;
  logic               sqrt_guard_bit;
  logic               sqrt_round_bit;
  logic               sqrt_sticky_bit;
  logic               sqrt_is_zero;

  // =========================================================================
  // Operand Unpacking
  // =========================================================================

  always_comb begin
    sign = operand_reg[31];
    exp = operand_reg[30:23];
    mant = operand_reg[22:0];

    is_zero = (exp == 8'b0) && (mant == 23'b0);
    is_inf = (exp == 8'hFF) && (mant == 23'b0);
    is_nan = (exp == 8'hFF) && (mant != 23'b0);
    is_snan = is_nan && ~mant[22];
    is_subnormal = (exp == 8'b0) && (mant != 23'b0);

    mant_lzc = 5'd0;
    sub_shift = 6'd0;
    exp_adj = 10'sb0;
    mant_norm = 24'b0;
    sqrt_unbiased_exp = 10'sb0;
    sqrt_exp_is_even = 1'b0;
    sqrt_adjusted_exp = 11'sb0;
    sqrt_mantissa_int = 25'b0;
    sqrt_shift_amount = 6'd0;

    mant_lzc_found = 1'b0;

    if (is_subnormal) begin
      for (int i = 22; i >= 0; i--) begin
        if (!mant_lzc_found) begin
          if (mant[i]) begin
            mant_lzc_found = 1'b1;
          end else begin
            mant_lzc = mant_lzc + 1;
          end
        end
      end
      sub_shift = {1'b0, mant_lzc} + 6'd1;
      exp_adj   = 10'sd1 - $signed({4'b0, sub_shift});
      mant_norm = {1'b0, mant} << sub_shift;
    end else begin
      exp_adj   = $signed({2'b0, exp});
      mant_norm = {1'b1, mant};
    end

    // Special case detection
    is_special = 1'b0;
    special_result = 32'b0;
    special_invalid = 1'b0;

    if (is_nan) begin
      // sqrt(NaN) = NaN
      is_special = 1'b1;
      special_result = riscv_pkg::FpCanonicalNan;
      special_invalid = is_snan;
    end else if (sign && !is_zero) begin
      // sqrt(negative) = NaN (invalid)
      is_special = 1'b1;
      special_result = riscv_pkg::FpCanonicalNan;
      special_invalid = 1'b1;
    end else if (is_inf) begin
      // sqrt(+inf) = +inf
      is_special = 1'b1;
      special_result = riscv_pkg::FpPosInf;
    end else if (is_zero) begin
      // sqrt(+/-0) = +/-0
      is_special = 1'b1;
      special_result = {sign, 31'b0};
    end

    sqrt_unbiased_exp = exp_adj - 10'sd127;
    sqrt_exp_is_even  = ~sqrt_unbiased_exp[0];

    if (sqrt_exp_is_even) begin
      // Unbiased exponent is even
      sqrt_adjusted_exp = exp_adj + 10'sd127;
      sqrt_mantissa_int = {1'b0, mant_norm};
      sqrt_shift_amount = 6'd29;
    end else begin
      // Unbiased exponent is odd: scale mantissa by 2
      sqrt_adjusted_exp = exp_adj + 10'sd126;
      sqrt_mantissa_int = {mant_norm, 1'b0};
      sqrt_shift_amount = 6'd29;
    end
  end

  assign sqrt_pre_round_mant = root[26:2];
  assign sqrt_guard_bit = root[1];
  assign sqrt_round_bit = root[0];
  assign sqrt_sticky_bit = |remainder;
  assign sqrt_is_zero = (root == 27'b0) && (remainder == 56'b0);

  // =========================================================================
  // ROUND_PREP: Subnormal handling and round-up decision (split rounding)
  // =========================================================================

  // Extract mantissa and rounding bits
  logic [23:0] mantissa_retained_prep;
  assign mantissa_retained_prep = sqrt_pre_round_mant[24:1];

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
    guard_work_prep = sqrt_pre_round_mant[0];
    round_work_prep = sqrt_guard_bit;
    sticky_work_prep = sqrt_round_bit | sqrt_sticky_bit;
    exp_work_prep = result_exp;
    mantissa_ext_prep = {
      mantissa_retained_prep,
      sqrt_pre_round_mant[0],
      sqrt_guard_bit,
      sqrt_round_bit | sqrt_sticky_bit
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

  // Compute round-up decision (sqrt result is always positive)
  logic round_up_prep;
  logic lsb_prep;

  assign lsb_prep = mantissa_work_prep[0];

  always_comb begin
    unique case (rm)
      riscv_pkg::FRM_RNE:
      round_up_prep = guard_work_prep & (round_work_prep | sticky_work_prep | lsb_prep);
      riscv_pkg::FRM_RTZ: round_up_prep = 1'b0;
      riscv_pkg::FRM_RDN: round_up_prep = 1'b0;  // sqrt result is always positive
      riscv_pkg::FRM_RUP: round_up_prep = guard_work_prep | round_work_prep | sticky_work_prep;
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

  logic signed [ 9:0] exp_work_apply;
  logic        [23:0] mantissa_work_apply;
  logic               round_up_apply;
  logic               is_inexact_apply;
  logic               sqrt_is_zero_apply;
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

  // Compute final result (sqrt result is always positive)
  logic [31:0] final_result_apply_comb;
  riscv_pkg::fp_flags_t final_flags_apply_comb;

  always_comb begin
    final_result_apply_comb = 32'b0;
    final_flags_apply_comb  = '0;

    if (sqrt_is_zero_apply) begin
      final_result_apply_comb = 32'b0;  // +0
    end else if (is_overflow_apply) begin
      final_flags_apply_comb.of = 1'b1;
      final_flags_apply_comb.nx = 1'b1;
      if (rm_apply == riscv_pkg::FRM_RTZ) begin
        final_result_apply_comb = {1'b0, 8'hFE, 23'h7FFFFF};
      end else begin
        final_result_apply_comb = {1'b0, 8'hFF, 23'b0};
      end
    end else if (is_underflow_apply) begin
      final_flags_apply_comb.uf = is_inexact_apply;
      final_flags_apply_comb.nx = is_inexact_apply;
      final_result_apply_comb   = {1'b0, 8'b0, final_mantissa_apply};
    end else begin
      final_flags_apply_comb.nx = is_inexact_apply;
      final_result_apply_comb   = {1'b0, adjusted_exponent_apply[7:0], final_mantissa_apply};
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
          next_state = SETUP;
        end
      end
      SETUP: begin
        if (is_special) begin
          next_state = DONE;
        end else begin
          next_state = COMPUTE;
        end
      end
      COMPUTE: begin
        if (cycle_count == 5'd26) begin
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
  // Main Datapath
  // =========================================================================

  logic                 [31:0] result_reg;
  riscv_pkg::fp_flags_t        flags_reg;
  logic                        valid_reg;

  // Digit-by-digit sqrt helpers
  logic                 [55:0] rem_candidate;
  logic                 [55:0] trial_divisor;
  logic                        rem_ge;

  assign rem_candidate = {remainder[53:0], radicand[53:52]};
  assign trial_divisor = {27'b0, root, 2'b01};
  assign rem_ge = rem_candidate >= trial_divisor;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      cycle_count <= 5'd0;
      root <= 27'b0;
      remainder <= 56'b0;
      radicand <= 54'b0;
      result_exp <= 10'sb0;
      rm <= 3'b0;
      result_sign <= 1'b0;
      operand_reg <= 32'b0;
      // ROUND_PREP -> ROUND_APPLY registers
      exp_work_apply <= 10'sb0;
      mantissa_work_apply <= 24'b0;
      round_up_apply <= 1'b0;
      is_inexact_apply <= 1'b0;
      sqrt_is_zero_apply <= 1'b0;
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
            operand_reg <= i_operand;
            rm <= i_rounding_mode;
            cycle_count <= 5'd0;
          end
        end

        SETUP: begin
          result_sign <= 1'b0;  // sqrt result is always positive (or zero)

          if (is_special) begin
            result_reg <= special_result;
            flags_reg  <= {special_invalid, 1'b0, 1'b0, 1'b0, 1'b0};
          end else begin
            // Initialize sqrt computation
            // For sqrt: result_exp = (exp - 127) / 2 + 127
            result_exp <= $signed(sqrt_adjusted_exp[10:1]);
            root <= 27'b0;
            remainder <= 56'b0;
            radicand <= {29'b0, sqrt_mantissa_int} << sqrt_shift_amount;
          end
        end

        COMPUTE: begin
          cycle_count <= cycle_count + 1;
          // Digit-by-digit square root: bring down 2 bits per iteration
          radicand <= {radicand[51:0], 2'b00};
          if (rem_ge) begin
            remainder <= rem_candidate - trial_divisor;
            root <= {root[25:0], 1'b1};
          end else begin
            remainder <= rem_candidate;
            root <= {root[25:0], 1'b0};
          end
        end

        NORMALIZE: begin
          // The root should already be normalized
          // root[26] should be the implicit 1
          if (!root[26]) begin
            root <= root << 1;
            result_exp <= result_exp - 1;
          end
        end

        ROUND_PREP: begin
          // Capture round-up decision into apply registers
          exp_work_apply <= exp_work_prep;
          mantissa_work_apply <= mantissa_work_prep;
          round_up_apply <= round_up_prep;
          is_inexact_apply <= is_inexact_prep;
          sqrt_is_zero_apply <= sqrt_is_zero;
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
  // Stall immediately when i_valid is asserted (FSQRT enters EX), matching integer
  // divider pattern where stall = (is_divide & ~divider_valid_output). The integer
  // stall is true from the first cycle because valid_output starts at 0. We achieve
  // the same by OR'ing i_valid with the state check, so stall is asserted on the
  // same cycle the instruction enters EX. Stall drops when valid_reg goes high.
  assign o_stall  = ((state != IDLE) || i_valid) && ~valid_reg;

endmodule : fp_sqrt
