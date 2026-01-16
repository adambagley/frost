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
  Floating-point to integer and integer to floating-point conversions.

  Operations:
    FCVT.W.S:  rd = (int32_t)fs1    - Convert FP to signed 32-bit integer
    FCVT.WU.S: rd = (uint32_t)fs1   - Convert FP to unsigned 32-bit integer
    FCVT.S.W:  fd = (float)rs1      - Convert signed 32-bit integer to FP
    FCVT.S.WU: fd = (float)rs1      - Convert unsigned 32-bit integer to FP
    FMV.X.W:   rd = bits(fs1)       - Move FP bits to integer (no conversion)
    FMV.W.X:   fd = bits(rs1)       - Move integer bits to FP (no conversion)

  Multi-cycle implementation (5-cycle latency):
    Cycle 0: Capture operands, unpack, compute LZC / shift amounts
    Cycle 1: FP->int shift/round prep, int->fp normalize
    Cycle 2: FP->int round add
    Cycle 3: Final pack/flags
    Cycle 4: Output registered result

  Rounding:
    - Integer to FP may require rounding (24-bit mantissa for 32-bit int)
    - FP to integer uses specified rounding mode

  Exception handling:
    - Invalid (NV): FP to int conversion of NaN, infinity, or out of range
    - Inexact (NX): Result is not exact
*/
module fp_convert #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    input logic [XLEN-1:0] i_fp_operand,  // FP source for FCVT.W/WU.S, FMV.X.W
    input logic [XLEN-1:0] i_int_operand,  // Integer source for FCVT.S.W/WU, FMV.W.X
    input riscv_pkg::instr_op_e i_operation,
    input logic [2:0] i_rounding_mode,
    output logic [XLEN-1:0] o_fp_result,  // Result for FCVT.S.W/WU, FMV.W.X
    output logic [XLEN-1:0] o_int_result,  // Result for FCVT.W/WU.S, FMV.X.W
    output logic o_is_fp_to_int,  // Result goes to integer register
    output logic o_valid,
    output riscv_pkg::fp_flags_t o_flags
);

  // =========================================================================
  // State Machine
  // =========================================================================
  typedef enum logic [2:0] {
    IDLE   = 3'b000,
    STAGE1 = 3'b001,
    STAGE2 = 3'b010,
    STAGE3 = 3'b011,
    STAGE4 = 3'b100
  } state_e;

  state_e state, next_state;

  // =========================================================================
  // Registered inputs
  // =========================================================================
  logic                 [XLEN-1:0] fp_operand_reg;
  logic                 [XLEN-1:0] int_operand_reg;
  riscv_pkg::instr_op_e            operation_reg;
  logic                 [     2:0] rm_reg;

  // =========================================================================
  // Stage 1: Unpack and prepare (combinational from registered inputs)
  // =========================================================================

  // FP field extraction
  logic                            fp_sign;
  logic                 [     7:0] fp_exp;
  logic                 [    22:0] fp_mant;
  logic fp_is_zero, fp_is_inf, fp_is_nan, fp_is_subnormal;
  logic [23:0] fp_mantissa;

  assign fp_sign         = fp_operand_reg[31];
  assign fp_exp          = fp_operand_reg[30:23];
  assign fp_mant         = fp_operand_reg[22:0];

  assign fp_is_zero      = (fp_exp == 8'h00) && (fp_mant == 23'b0);
  assign fp_is_subnormal = (fp_exp == 8'h00) && (fp_mant != 23'b0);
  assign fp_is_inf       = (fp_exp == 8'hFF) && (fp_mant == 23'b0);
  assign fp_is_nan       = (fp_exp == 8'hFF) && (fp_mant != 23'b0);
  assign fp_mantissa     = (fp_exp == 8'h00) ? {1'b0, fp_mant} : {1'b1, fp_mant};

  // Unbiased exponent
  logic signed [8:0] unbiased_exp;
  assign unbiased_exp = (fp_exp == 8'h00) ? -9'sd126 : $signed({1'b0, fp_exp}) - 9'sd127;

  // Integer to FP: get absolute value and compute LZC
  logic [31:0] abs_int;
  logic        int_sign;
  logic        is_signed_conv;
  logic [ 4:0] int_lzc;
  logic        int_lzc_found;

  assign is_signed_conv = (operation_reg == riscv_pkg::FCVT_S_W);

  always_comb begin
    if (is_signed_conv && int_operand_reg[31]) begin
      abs_int  = -int_operand_reg;
      int_sign = 1'b1;
    end else begin
      abs_int  = int_operand_reg;
      int_sign = 1'b0;
    end
  end

  // LZC for integer to FP - computed combinationally in stage 1
  always_comb begin
    int_lzc = 5'd0;
    int_lzc_found = 1'b0;
    for (int i = 31; i >= 0; i--) begin
      if (!int_lzc_found) begin
        if (abs_int[i]) begin
          int_lzc_found = 1'b1;
        end else begin
          int_lzc = int_lzc + 1;
        end
      end
    end
  end

  // =========================================================================
  // Stage 1 -> Stage 2 Pipeline Registers
  // =========================================================================
  logic        fp_sign_s2;
  logic [ 7:0] fp_exp_s2;
  logic [23:0] fp_mantissa_s2;
  logic fp_is_zero_s2, fp_is_inf_s2, fp_is_nan_s2;
  logic signed          [     8:0] unbiased_exp_s2;
  logic                 [    31:0] abs_int_s2;
  logic                            int_sign_s2;
  logic                            int_is_zero_s2;
  logic                 [     4:0] int_lzc_s2;
  riscv_pkg::instr_op_e            operation_s2;
  logic                 [     2:0] rm_s2;

  // =========================================================================
  // Stage 2 -> Stage 3 Pipeline Registers
  // =========================================================================
  logic                 [    31:0] fp_to_int_shifted_value_s3;
  logic                            fp_to_int_round_bit_s3;
  logic                            fp_to_int_sticky_bit_s3;
  logic                            fp_to_int_inexact_pre_s3;
  logic                            fp_to_int_force_valid_s3;
  logic                 [    31:0] fp_to_int_force_result_s3;
  logic                            fp_to_int_force_invalid_s3;
  logic                            fp_to_int_force_inexact_s3;
  logic                            fp_to_int_sign_s3;
  logic                            fp_to_int_is_unsigned_s3;
  logic                 [     2:0] rm_s3;
  riscv_pkg::instr_op_e            operation_s3;
  logic                 [XLEN-1:0] int_to_fp_result_s3;
  logic                            int_to_fp_inexact_s3;
  logic                 [XLEN-1:0] move_fp_result_s3;
  logic                 [XLEN-1:0] move_int_result_s3;

  // =========================================================================
  // Stage 3 -> Stage 4 Pipeline Registers
  // =========================================================================
  logic                 [    32:0] fp_to_int_rounded_value_s4;
  logic                            fp_to_int_do_round_up_s4;
  logic                 [    31:0] fp_to_int_shifted_value_s4;
  logic                            fp_to_int_inexact_pre_s4;
  logic                            fp_to_int_force_valid_s4;
  logic                 [    31:0] fp_to_int_force_result_s4;
  logic                            fp_to_int_force_invalid_s4;
  logic                            fp_to_int_force_inexact_s4;
  logic                            fp_to_int_sign_s4;
  logic                            fp_to_int_is_unsigned_s4;
  riscv_pkg::instr_op_e            operation_s4;
  logic                 [XLEN-1:0] int_to_fp_result_s4;
  logic                            int_to_fp_inexact_s4;
  logic                 [XLEN-1:0] move_fp_result_s4;
  logic                 [XLEN-1:0] move_int_result_s4;

  // =========================================================================
  // Stage 2: FP->int prep, int->fp compute (combinational from stage 2 regs)
  // =========================================================================

  // FP to Integer conversion
  logic                            is_unsigned_conv;
  logic                            fp_to_int_force_valid_s2_comb;
  logic                 [    31:0] fp_to_int_force_result_s2_comb;
  logic                            fp_to_int_force_invalid_s2_comb;
  logic                            fp_to_int_force_inexact_s2_comb;
  logic                 [    31:0] fp_to_int_shifted_value_s2_comb;
  logic                            fp_to_int_round_bit_s2_comb;
  logic                            fp_to_int_sticky_bit_s2_comb;
  logic                            fp_to_int_inexact_pre_s2_comb;

  logic                 [    55:0] extended_mant;
  logic                 [    31:0] shifted_value;
  logic round_bit, sticky_bit;
  logic [ 5:0] fp_to_int_shift_amt;
  logic [55:0] fp_to_int_shifted_ext;

  always_comb begin
    is_unsigned_conv = (operation_s2 == riscv_pkg::FCVT_WU_S);
    fp_to_int_force_valid_s2_comb = 1'b0;
    fp_to_int_force_result_s2_comb = 32'b0;
    fp_to_int_force_invalid_s2_comb = 1'b0;
    fp_to_int_force_inexact_s2_comb = 1'b0;
    fp_to_int_shifted_value_s2_comb = 32'b0;
    fp_to_int_round_bit_s2_comb = 1'b0;
    fp_to_int_sticky_bit_s2_comb = 1'b0;
    fp_to_int_inexact_pre_s2_comb = 1'b0;
    extended_mant = 56'b0;
    shifted_value = 32'b0;
    round_bit = 1'b0;
    sticky_bit = 1'b0;
    fp_to_int_shift_amt = 6'b0;
    fp_to_int_shifted_ext = 56'b0;

    if (fp_is_nan_s2) begin
      fp_to_int_force_valid_s2_comb   = 1'b1;
      fp_to_int_force_invalid_s2_comb = 1'b1;
      fp_to_int_force_result_s2_comb  = is_unsigned_conv ? 32'hFFFF_FFFF : 32'h7FFF_FFFF;
    end else if (fp_is_inf_s2) begin
      fp_to_int_force_valid_s2_comb   = 1'b1;
      fp_to_int_force_invalid_s2_comb = 1'b1;
      if (fp_sign_s2) begin
        fp_to_int_force_result_s2_comb = is_unsigned_conv ? 32'h0000_0000 : 32'h8000_0000;
      end else begin
        fp_to_int_force_result_s2_comb = is_unsigned_conv ? 32'hFFFF_FFFF : 32'h7FFF_FFFF;
      end
    end else if (fp_is_zero_s2) begin
      fp_to_int_force_valid_s2_comb  = 1'b1;
      fp_to_int_force_result_s2_comb = 32'b0;
    end else begin
      extended_mant = {fp_mantissa_s2, 32'b0};

      if (unbiased_exp_s2 < 0) begin
        shifted_value = 32'b0;
        round_bit = (unbiased_exp_s2 == -1) ? extended_mant[55] : 1'b0;
        sticky_bit = (unbiased_exp_s2 == -1) ? |extended_mant[54:0] : |extended_mant[55:0];
        fp_to_int_inexact_pre_s2_comb = 1'b1;
      end else if (unbiased_exp_s2 > 30) begin
        if (is_unsigned_conv && !fp_sign_s2 && unbiased_exp_s2 <= 31) begin
          shifted_value = 32'b0;
          if (unbiased_exp_s2 == 31) begin
            shifted_value = {fp_mantissa_s2, 8'b0};
          end
          round_bit  = 1'b0;
          sticky_bit = 1'b0;
        end else begin
          fp_to_int_force_valid_s2_comb   = 1'b1;
          fp_to_int_force_invalid_s2_comb = 1'b1;
          if (fp_sign_s2) begin
            fp_to_int_force_result_s2_comb = is_unsigned_conv ? 32'h0000_0000 : 32'h8000_0000;
          end else begin
            fp_to_int_force_result_s2_comb = is_unsigned_conv ? 32'hFFFF_FFFF : 32'h7FFF_FFFF;
          end
          shifted_value = 32'b0;
          round_bit = 1'b0;
          sticky_bit = 1'b0;
        end
      end else begin
        if (unbiased_exp_s2 >= 23) begin
          // verilator lint_off WIDTHTRUNC
          shifted_value = {9'b0, fp_mantissa_s2} << (unbiased_exp_s2 - 23);
          // verilator lint_on WIDTHTRUNC
          round_bit = 1'b0;
          sticky_bit = 1'b0;
        end else begin
          fp_to_int_shift_amt = 6'd31 - unbiased_exp_s2[5:0];
          fp_to_int_shifted_ext = extended_mant >> fp_to_int_shift_amt;
          shifted_value = fp_to_int_shifted_ext[55:24];
          round_bit = fp_to_int_shifted_ext[23];
          sticky_bit = |fp_to_int_shifted_ext[22:0];
          fp_to_int_inexact_pre_s2_comb = round_bit | sticky_bit;
        end
      end
    end

    fp_to_int_shifted_value_s2_comb = shifted_value;
    fp_to_int_round_bit_s2_comb = round_bit;
    fp_to_int_sticky_bit_s2_comb = sticky_bit;
  end

  // Integer to FP conversion
  logic [XLEN-1:0] int_to_fp_result;
  logic            int_to_fp_inexact;

  logic [    31:0] int_to_fp_normalized_mant;
  logic [     7:0] int_to_fp_result_exp;
  logic [    22:0] int_to_fp_mant_23;
  logic int_to_fp_r_bit, int_to_fp_s_bit;
  logic        int_to_fp_round_up;
  logic [23:0] int_to_fp_rounded_mant;
  logic        is_signed_conv_s2;

  always_comb begin
    int_to_fp_result = 32'b0;
    int_to_fp_inexact = 1'b0;
    is_signed_conv_s2 = (operation_s2 == riscv_pkg::FCVT_S_W);
    int_to_fp_normalized_mant = 32'b0;
    int_to_fp_result_exp = 8'd0;
    int_to_fp_mant_23 = 23'b0;
    int_to_fp_r_bit = 1'b0;
    int_to_fp_s_bit = 1'b0;
    int_to_fp_round_up = 1'b0;
    int_to_fp_rounded_mant = 24'b0;

    if (int_is_zero_s2) begin
      int_to_fp_result = {int_sign_s2, 31'b0};
    end else begin
      // Use pre-computed LZC to normalize
      int_to_fp_normalized_mant = abs_int_s2 << int_lzc_s2;
      int_to_fp_result_exp = 8'd158 - {3'b0, int_lzc_s2};

      int_to_fp_mant_23 = int_to_fp_normalized_mant[30:8];
      int_to_fp_r_bit = int_to_fp_normalized_mant[7];
      int_to_fp_s_bit = |int_to_fp_normalized_mant[6:0];

      int_to_fp_inexact = int_to_fp_r_bit | int_to_fp_s_bit;

      unique case (rm_s2)
        riscv_pkg::FRM_RNE:
        int_to_fp_round_up = int_to_fp_r_bit & (int_to_fp_s_bit | int_to_fp_mant_23[0]);
        riscv_pkg::FRM_RTZ: int_to_fp_round_up = 1'b0;
        riscv_pkg::FRM_RDN: int_to_fp_round_up = int_sign_s2 & (int_to_fp_r_bit | int_to_fp_s_bit);
        riscv_pkg::FRM_RUP: int_to_fp_round_up = !int_sign_s2 & (int_to_fp_r_bit | int_to_fp_s_bit);
        riscv_pkg::FRM_RMM: int_to_fp_round_up = int_to_fp_r_bit;
        default: int_to_fp_round_up = int_to_fp_r_bit & (int_to_fp_s_bit | int_to_fp_mant_23[0]);
      endcase

      int_to_fp_rounded_mant = {1'b0, int_to_fp_mant_23} + {23'b0, int_to_fp_round_up};

      if (int_to_fp_rounded_mant[23]) begin
        int_to_fp_result_exp = int_to_fp_result_exp + 1;
        int_to_fp_mant_23 = 23'b0;
      end else begin
        int_to_fp_mant_23 = int_to_fp_rounded_mant[22:0];
      end

      int_to_fp_result = {int_sign_s2, int_to_fp_result_exp, int_to_fp_mant_23};
    end
  end

  logic [XLEN-1:0] move_fp_result_s2_comb;
  logic [XLEN-1:0] move_int_result_s2_comb;

  assign move_fp_result_s2_comb  = int_operand_reg;
  assign move_int_result_s2_comb = fp_operand_reg;

  // =========================================================================
  // Stage 3: FP->int rounding add (combinational from stage 3 regs)
  // =========================================================================
  logic fp_to_int_do_round_up_s3_comb;
  logic [32:0] fp_to_int_rounded_value_s3_comb;

  always_comb begin
    fp_to_int_do_round_up_s3_comb   = 1'b0;
    fp_to_int_rounded_value_s3_comb = 33'b0;

    if (!fp_to_int_force_valid_s3) begin
      unique case (rm_s3)
        riscv_pkg::FRM_RNE:
        fp_to_int_do_round_up_s3_comb = fp_to_int_round_bit_s3 &
                                        (fp_to_int_sticky_bit_s3 | fp_to_int_shifted_value_s3[0]);
        riscv_pkg::FRM_RTZ: fp_to_int_do_round_up_s3_comb = 1'b0;
        riscv_pkg::FRM_RDN:
        fp_to_int_do_round_up_s3_comb = fp_to_int_sign_s3 &
                                        (fp_to_int_round_bit_s3 | fp_to_int_sticky_bit_s3);
        riscv_pkg::FRM_RUP:
        fp_to_int_do_round_up_s3_comb = ~fp_to_int_sign_s3 &
                                        (fp_to_int_round_bit_s3 | fp_to_int_sticky_bit_s3);
        riscv_pkg::FRM_RMM: fp_to_int_do_round_up_s3_comb = fp_to_int_round_bit_s3;
        default:
        fp_to_int_do_round_up_s3_comb = fp_to_int_round_bit_s3 &
                                        (fp_to_int_sticky_bit_s3 | fp_to_int_shifted_value_s3[0]);
      endcase

      fp_to_int_rounded_value_s3_comb =
          {1'b0, fp_to_int_shifted_value_s3} + {32'b0, fp_to_int_do_round_up_s3_comb};
    end
  end

  // =========================================================================
  // Stage 4: Compute final result (combinational from stage 4 regs)
  // =========================================================================
  logic [XLEN-1:0] final_fp_result_s4_comb;
  logic [XLEN-1:0] final_int_result_s4_comb;
  logic final_is_fp_to_int_s4_comb;
  riscv_pkg::fp_flags_t final_flags_s4_comb;
  logic fp_to_int_invalid_s4_comb;

  always_comb begin
    final_fp_result_s4_comb = 32'b0;
    final_int_result_s4_comb = 32'b0;
    final_is_fp_to_int_s4_comb = 1'b0;
    final_flags_s4_comb = '0;
    fp_to_int_invalid_s4_comb = 1'b0;

    unique case (operation_s4)
      riscv_pkg::FCVT_W_S, riscv_pkg::FCVT_WU_S: begin
        final_is_fp_to_int_s4_comb = 1'b1;

        if (fp_to_int_force_valid_s4) begin
          final_int_result_s4_comb = fp_to_int_force_result_s4;
          final_flags_s4_comb.nv   = fp_to_int_force_invalid_s4;
          final_flags_s4_comb.nx   = fp_to_int_force_inexact_s4;
        end else begin
          if (fp_to_int_sign_s4) begin
            if (fp_to_int_is_unsigned_s4) begin
              if (fp_to_int_shifted_value_s4 != 0 || fp_to_int_do_round_up_s4) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = 32'h0000_0000;
              end else begin
                final_int_result_s4_comb = 32'b0;
              end
            end else begin
              if (fp_to_int_rounded_value_s4 > 33'h8000_0000) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = 32'h8000_0000;
              end else begin
                final_int_result_s4_comb = -fp_to_int_rounded_value_s4[31:0];
              end
            end
          end else begin
            if (fp_to_int_is_unsigned_s4) begin
              if (fp_to_int_rounded_value_s4[32]) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = 32'hFFFF_FFFF;
              end else begin
                final_int_result_s4_comb = fp_to_int_rounded_value_s4[31:0];
              end
            end else begin
              if (fp_to_int_rounded_value_s4 > 33'h7FFF_FFFF) begin
                fp_to_int_invalid_s4_comb = 1'b1;
                final_int_result_s4_comb  = 32'h7FFF_FFFF;
              end else begin
                final_int_result_s4_comb = fp_to_int_rounded_value_s4[31:0];
              end
            end
          end

          final_flags_s4_comb.nv = fp_to_int_invalid_s4_comb;
          final_flags_s4_comb.nx = fp_to_int_inexact_pre_s4 & ~fp_to_int_invalid_s4_comb;
        end
      end

      riscv_pkg::FCVT_S_W, riscv_pkg::FCVT_S_WU: begin
        final_fp_result_s4_comb = int_to_fp_result_s4;
        final_flags_s4_comb.nx  = int_to_fp_inexact_s4;
      end

      riscv_pkg::FMV_X_W: begin
        final_int_result_s4_comb   = move_int_result_s4;
        final_is_fp_to_int_s4_comb = 1'b1;
      end

      riscv_pkg::FMV_W_X: begin
        final_fp_result_s4_comb = move_fp_result_s4;
      end

      default: begin
        final_fp_result_s4_comb = 32'b0;
        final_int_result_s4_comb = 32'b0;
        final_is_fp_to_int_s4_comb = 1'b0;
      end
    endcase
  end

  // =========================================================================
  // Stage 4 -> Output Registers
  // =========================================================================
  logic [XLEN-1:0] fp_result_out;
  logic [XLEN-1:0] int_result_out;
  logic is_fp_to_int_out;
  riscv_pkg::fp_flags_t flags_out;

  // =========================================================================
  // State Machine and Sequential Logic
  // =========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      fp_operand_reg <= 32'b0;
      int_operand_reg <= 32'b0;
      operation_reg <= riscv_pkg::instr_op_e'(0);
      rm_reg <= 3'b0;
      // Stage 2 registers
      fp_sign_s2 <= 1'b0;
      fp_exp_s2 <= 8'b0;
      fp_mantissa_s2 <= 24'b0;
      fp_is_zero_s2 <= 1'b0;
      fp_is_inf_s2 <= 1'b0;
      fp_is_nan_s2 <= 1'b0;
      unbiased_exp_s2 <= 9'sb0;
      abs_int_s2 <= 32'b0;
      int_sign_s2 <= 1'b0;
      int_is_zero_s2 <= 1'b0;
      int_lzc_s2 <= 5'b0;
      operation_s2 <= riscv_pkg::instr_op_e'(0);
      rm_s2 <= 3'b0;
      // Stage 3 registers
      fp_to_int_shifted_value_s3 <= 32'b0;
      fp_to_int_round_bit_s3 <= 1'b0;
      fp_to_int_sticky_bit_s3 <= 1'b0;
      fp_to_int_inexact_pre_s3 <= 1'b0;
      fp_to_int_force_valid_s3 <= 1'b0;
      fp_to_int_force_result_s3 <= 32'b0;
      fp_to_int_force_invalid_s3 <= 1'b0;
      fp_to_int_force_inexact_s3 <= 1'b0;
      fp_to_int_sign_s3 <= 1'b0;
      fp_to_int_is_unsigned_s3 <= 1'b0;
      rm_s3 <= 3'b0;
      operation_s3 <= riscv_pkg::instr_op_e'(0);
      int_to_fp_result_s3 <= 32'b0;
      int_to_fp_inexact_s3 <= 1'b0;
      move_fp_result_s3 <= 32'b0;
      move_int_result_s3 <= 32'b0;
      // Stage 4 registers
      fp_to_int_rounded_value_s4 <= 33'b0;
      fp_to_int_do_round_up_s4 <= 1'b0;
      fp_to_int_shifted_value_s4 <= 32'b0;
      fp_to_int_inexact_pre_s4 <= 1'b0;
      fp_to_int_force_valid_s4 <= 1'b0;
      fp_to_int_force_result_s4 <= 32'b0;
      fp_to_int_force_invalid_s4 <= 1'b0;
      fp_to_int_force_inexact_s4 <= 1'b0;
      fp_to_int_sign_s4 <= 1'b0;
      fp_to_int_is_unsigned_s4 <= 1'b0;
      operation_s4 <= riscv_pkg::instr_op_e'(0);
      int_to_fp_result_s4 <= 32'b0;
      int_to_fp_inexact_s4 <= 1'b0;
      move_fp_result_s4 <= 32'b0;
      move_int_result_s4 <= 32'b0;
      // Output registers
      fp_result_out <= 32'b0;
      int_result_out <= 32'b0;
      is_fp_to_int_out <= 1'b0;
      flags_out <= '0;
    end else begin
      state <= next_state;

      case (state)
        IDLE: begin
          if (i_valid) begin
            fp_operand_reg <= i_fp_operand;
            int_operand_reg <= i_int_operand;
            operation_reg <= i_operation;
            rm_reg <= i_rounding_mode;
          end
        end

        STAGE1: begin
          // Capture stage 1 results
          fp_sign_s2 <= fp_sign;
          fp_exp_s2 <= fp_exp;
          fp_mantissa_s2 <= fp_mantissa;
          fp_is_zero_s2 <= fp_is_zero;
          fp_is_inf_s2 <= fp_is_inf;
          fp_is_nan_s2 <= fp_is_nan;
          unbiased_exp_s2 <= unbiased_exp;
          abs_int_s2 <= abs_int;
          int_sign_s2 <= int_sign;
          int_is_zero_s2 <= (abs_int == 32'b0);
          int_lzc_s2 <= int_lzc;
          operation_s2 <= operation_reg;
          rm_s2 <= rm_reg;
        end

        STAGE2: begin
          fp_to_int_shifted_value_s3 <= fp_to_int_shifted_value_s2_comb;
          fp_to_int_round_bit_s3 <= fp_to_int_round_bit_s2_comb;
          fp_to_int_sticky_bit_s3 <= fp_to_int_sticky_bit_s2_comb;
          fp_to_int_inexact_pre_s3 <= fp_to_int_inexact_pre_s2_comb;
          fp_to_int_force_valid_s3 <= fp_to_int_force_valid_s2_comb;
          fp_to_int_force_result_s3 <= fp_to_int_force_result_s2_comb;
          fp_to_int_force_invalid_s3 <= fp_to_int_force_invalid_s2_comb;
          fp_to_int_force_inexact_s3 <= fp_to_int_force_inexact_s2_comb;
          fp_to_int_sign_s3 <= fp_sign_s2;
          fp_to_int_is_unsigned_s3 <= is_unsigned_conv;
          rm_s3 <= rm_s2;
          operation_s3 <= operation_s2;
          int_to_fp_result_s3 <= int_to_fp_result;
          int_to_fp_inexact_s3 <= int_to_fp_inexact;
          move_fp_result_s3 <= move_fp_result_s2_comb;
          move_int_result_s3 <= move_int_result_s2_comb;
        end

        STAGE3: begin
          fp_to_int_rounded_value_s4 <= fp_to_int_rounded_value_s3_comb;
          fp_to_int_do_round_up_s4 <= fp_to_int_do_round_up_s3_comb;
          fp_to_int_shifted_value_s4 <= fp_to_int_shifted_value_s3;
          fp_to_int_inexact_pre_s4 <= fp_to_int_inexact_pre_s3;
          fp_to_int_force_valid_s4 <= fp_to_int_force_valid_s3;
          fp_to_int_force_result_s4 <= fp_to_int_force_result_s3;
          fp_to_int_force_invalid_s4 <= fp_to_int_force_invalid_s3;
          fp_to_int_force_inexact_s4 <= fp_to_int_force_inexact_s3;
          fp_to_int_sign_s4 <= fp_to_int_sign_s3;
          fp_to_int_is_unsigned_s4 <= fp_to_int_is_unsigned_s3;
          operation_s4 <= operation_s3;
          int_to_fp_result_s4 <= int_to_fp_result_s3;
          int_to_fp_inexact_s4 <= int_to_fp_inexact_s3;
          move_fp_result_s4 <= move_fp_result_s3;
          move_int_result_s4 <= move_int_result_s3;
        end

        STAGE4: begin
          fp_result_out <= final_fp_result_s4_comb;
          int_result_out <= final_int_result_s4_comb;
          is_fp_to_int_out <= final_is_fp_to_int_s4_comb;
          flags_out <= final_flags_s4_comb;
        end

        default: ;
      endcase
    end
  end

  // Next state logic
  always_comb begin
    next_state = state;
    case (state)
      IDLE: if (i_valid) next_state = STAGE1;
      STAGE1: next_state = STAGE2;
      STAGE2: next_state = STAGE3;
      STAGE3: next_state = STAGE4;
      STAGE4: next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end

  // =========================================================================
  // Output Logic
  // =========================================================================
  logic valid_reg;
  always_ff @(posedge i_clk) begin
    if (i_rst) valid_reg <= 1'b0;
    else valid_reg <= (state == STAGE4);
  end
  assign o_valid = valid_reg;

  // Output from registered stage 4
  assign o_fp_result = fp_result_out;
  assign o_int_result = int_result_out;
  assign o_is_fp_to_int = is_fp_to_int_out;
  assign o_flags = flags_out;

endmodule : fp_convert
