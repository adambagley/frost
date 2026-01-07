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
 * LR/SC Reservation Register
 *
 * Implements the reservation register for RISC-V A extension Load-Reserved (LR.W)
 * and Store-Conditional (SC.W) atomic synchronization primitives.
 *
 * Operation:
 * ==========
 *   - LR.W: Loads a word and sets a reservation on the address
 *   - SC.W: Attempts to store if reservation is valid and address matches
 *   - Reservation is cleared on any SC.W (success or fail) or reset
 *
 * Forwarding:
 * ===========
 *   When LR is in MA stage and SC is in EX stage (back-to-back), the registered
 *   reservation isn't set yet. The lr_in_flight signals forward this info so SC
 *   can see the pending reservation.
 *
 * Related Modules:
 *   - cpu.sv: Instantiates this module
 *   - store_unit.sv: Uses reservation for SC success/fail determination
 *   - ex_stage.sv: Passes reservation to store_unit
 */
module lr_sc_reservation #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stall,

    // LR detection (from EX→MA pipeline register)
    input logic i_is_lr_in_ma,
    input logic [XLEN-1:0] i_lr_address,

    // SC detection (from ID→EX pipeline register)
    input logic i_is_sc_in_ex,

    // Reservation state output
    output riscv_pkg::reservation_t o_reservation
);

  // Registered reservation state
  logic valid_registered;
  logic [XLEN-1:0] address_registered;

  // Combinatorial forwarding: indicate LR is in MA stage (will set reservation next cycle)
  // Note: We don't gate with ~stall to avoid combinational loop through pipeline_ctrl.
  // During a stall, SC result is held anyway, so forwarding is still safe.
  assign o_reservation.lr_in_flight = i_is_lr_in_ma;
  assign o_reservation.lr_in_flight_addr = i_lr_address;
  assign o_reservation.valid = valid_registered;
  assign o_reservation.address = address_registered;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      valid_registered   <= 1'b0;
      address_registered <= '0;
    end else if (~i_stall) begin
      // Clear reservation when SC.W is being executed
      if (i_is_sc_in_ex) begin
        valid_registered <= 1'b0;
      end  // Set reservation when LR.W completes (loads data in MA stage)
      else if (i_is_lr_in_ma) begin
        valid_registered   <= 1'b1;
        address_registered <= i_lr_address;
      end
    end
  end

endmodule : lr_sc_reservation
