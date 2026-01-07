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
 * Single-Cycle Registered Multiplier - RISC-V M-extension multiply operations
 *
 * Implements a 1-cycle latency multiplier for MUL, MULH, MULHSU, MULHU instructions.
 * Takes 33-bit inputs (sign-extended for signed operations) and produces 64-bit result.
 * Uses FPGA DSP blocks for fast 33x33 signed multiplication.
 *
 * Timing:
 *   - 1-cycle latency: result available at next clock edge after inputs
 *   - Registered output breaks critical timing path through DSP
 *   - Requires 1-cycle stall for dependent instructions
 *
 * Pipeline Integration:
 *   Cycle N: MUL in EX - operands presented, multiply computes
 *   Cycle N+1: MUL in MA - o_product_result has correct value (registered)
 *   The multiply result must be captured separately since o_product_result
 *   is registered and not available combinationally in the same cycle.
 *
 * Operand Sign Handling (in ALU):
 *   MUL:    Both operands zero-extended (33'b0, rs1/rs2)
 *   MULH:   Both operands sign-extended ({rs[31], rs})
 *   MULHSU: rs1 sign-extended, rs2 zero-extended
 *   MULHU:  Both operands zero-extended
 *
 * Related Modules:
 *   - alu.sv: Instantiates multiplier, selects result portion (low/high 32 bits)
 *   - hazard_resolution_unit.sv: Stalls pipeline for 1 cycle during multiply
 */
module multiplier (
    input logic i_clk,
    input logic signed [32:0] i_operand_a,  // 33-bit signed input (sign-extend for signed multiply)
    input logic signed [32:0] i_operand_b,  // 33-bit signed input
    input logic i_valid_input,  // Start multiplication
    output logic [63:0] o_product_result,  // 64-bit product output (registered)
    output logic o_valid_output,  // Result ready (1 cycle after valid input)
    // Signals completion next cycle - used by hazard unit to end stall
    output logic o_completing_next_cycle
);

  // Single-cycle registered multiplication using DSP blocks
  // The multiply is computed combinationally but the output is registered,
  // breaking the critical timing path through the DSP chain.
  always_ff @(posedge i_clk) begin
    o_product_result <= 64'(i_operand_a * i_operand_b);
    o_valid_output   <= i_valid_input;
  end

  // Signal that multiply will complete next cycle (when i_valid_input is high)
  // This allows hazard unit to anticipate completion and end stall early
  assign o_completing_next_cycle = i_valid_input;

endmodule : multiplier
