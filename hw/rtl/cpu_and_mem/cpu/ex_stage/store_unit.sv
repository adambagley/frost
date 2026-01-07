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
 * Store Unit - Memory address calculation and data alignment for RISC-V stores
 *
 * This module handles all aspects of memory write preparation:
 *   - Effective address calculation (base + offset)
 *   - Data alignment for sub-word stores (SB, SH)
 *   - Per-byte write enable generation
 *   - SC.W (store-conditional) success/fail determination
 *
 * Supported Instructions:
 * =======================
 *   SB   - Store Byte:     mem[addr] ← rs2[7:0]
 *   SH   - Store Halfword: mem[addr] ← rs2[15:0]
 *   SW   - Store Word:     mem[addr] ← rs2[31:0]
 *   SC.W - Store Conditional: mem[addr] ← rs2 if reservation valid
 *
 * Address Calculation:
 * ====================
 *   Load:  effective_addr = rs1 + sign_extend(imm_i)
 *   Store: effective_addr = rs1 + sign_extend(imm_s)
 *   AMO:   effective_addr = rs1 (no offset, word-aligned)
 *
 * Data Alignment (Little-Endian):
 * ===============================
 *   addr[1:0]=00: data stays at bits [7:0] / [15:0] / [31:0]
 *   addr[1:0]=01: SB data shifts to bits [15:8]
 *   addr[1:0]=10: SB/SH data shifts to bits [23:16] / [31:16]
 *   addr[1:0]=11: SB data shifts to bits [31:24]
 *
 * Write Enable Patterns:
 *   SB: 0001, 0010, 0100, 1000 (based on addr[1:0])
 *   SH: 0011, 1100            (based on addr[1])
 *   SW: 1111                  (always all bytes)
 *
 * Related Modules:
 *   - ex_stage.sv: Instantiates this unit
 *   - load_unit.sv: Complementary unit for load data extraction
 *   - amo_unit.sv: Uses store data path for AMO write phase
 */
module store_unit #(
    parameter int unsigned XLEN = 32
) (
    // Store operation type (from instruction decode)
    input riscv_pkg::store_op_e i_store_operation,

    // Operands (forwarded values)
    input logic [XLEN-1:0] i_source_reg_1_value,  // Base address (rs1)
    input logic [XLEN-1:0] i_source_reg_2_value,  // Store data (rs2)

    // Immediate offsets (sign-extended)
    input logic [31:0] i_immediate_i_type,  // For loads (I-format)
    input logic [31:0] i_immediate_s_type,  // For stores (S-format)

    // Load instruction flags (for address mux)
    input logic i_is_load_instruction,
    input logic i_is_load_halfword,

    // A-extension: AMO uses rs1 directly, SC.W checks reservation
    input logic i_is_amo_instruction,
    input logic i_is_sc,
    input riscv_pkg::reservation_t i_reservation,

    // Outputs
    output logic [XLEN-1:0] o_data_memory_address,  // Effective address
    output logic [XLEN-1:0] o_data_memory_write_data,  // Aligned store data
    output logic [3:0] o_data_memory_byte_write_enable,  // Per-byte write strobes
    output logic o_sc_success,  // SC.W result: 1=success (write), 0=fail (no write)

    // TIMING OPTIMIZATION: Fast path for address low bits (for misalignment detection)
    // Computed directly without waiting for CARRY8 chain
    output logic [1:0] o_data_memory_address_low
);

  // Calculate effective addresses for loads and stores
  logic [XLEN-1:0] full_store_address, full_load_address;
  logic [1:0] store_byte_offset;  // Which byte within word (0-3)

  // Effective address = base register + sign-extended immediate offset
  assign full_store_address = i_source_reg_1_value + XLEN'(signed'(i_immediate_s_type));
  assign full_load_address = i_source_reg_1_value + XLEN'(signed'(i_immediate_i_type));
  // Output the appropriate address based on whether this is a load or store
  // AMO instructions use rs1 directly without any offset, word-aligned (RISC-V spec requires aligned addresses)
  assign o_data_memory_address = i_is_amo_instruction ? (i_source_reg_1_value & ~32'h3) :
                                 i_is_load_instruction ? full_load_address : full_store_address;

  // Extract byte offset within word for sub-word stores (used for alignment)
  assign store_byte_offset = full_store_address[1:0];

  // ===========================================================================
  // TIMING OPTIMIZATION: Fast Address Low Bits for Misalignment Detection
  // ===========================================================================
  // Compute address[1:0] directly without waiting for the full CARRY8 chain.
  // For misalignment detection, we only need the low 2 bits:
  //   addr[0] = rs1[0] ^ imm[0]
  //   addr[1] = rs1[1] ^ imm[1] ^ carry_from_bit0
  // where carry_from_bit0 = rs1[0] & imm[0]
  //
  // This allows misalignment detection to start ~1 CARRY8 level earlier.
  logic [1:0] addr_low_store, addr_low_load;
  logic carry0_store, carry0_load;

  // Store address low bits (rs1 + imm_s)
  assign carry0_store = i_source_reg_1_value[0] & i_immediate_s_type[0];
  assign addr_low_store[0] = i_source_reg_1_value[0] ^ i_immediate_s_type[0];
  assign addr_low_store[1] = i_source_reg_1_value[1] ^ i_immediate_s_type[1] ^ carry0_store;

  // Load address low bits (rs1 + imm_i)
  assign carry0_load = i_source_reg_1_value[0] & i_immediate_i_type[0];
  assign addr_low_load[0] = i_source_reg_1_value[0] ^ i_immediate_i_type[0];
  assign addr_low_load[1] = i_source_reg_1_value[1] ^ i_immediate_i_type[1] ^ carry0_load;

  // Select based on instruction type (AMO uses rs1 directly, always word-aligned = 2'b00)
  assign o_data_memory_address_low = i_is_amo_instruction ? 2'b00 :
                                     i_is_load_instruction ? addr_low_load :
                                     addr_low_store;

  // A extension: SC.W success check
  // SC.W succeeds if reservation is valid and addresses match (word-aligned comparison)
  // Also check forwarding: if LR is in MA stage with matching address, SC succeeds
  logic sc_reservation_valid;
  logic sc_forward_valid;
  assign sc_reservation_valid = i_reservation.valid &&
                                (i_reservation.address[XLEN-1:2] == i_source_reg_1_value[XLEN-1:2]);
  assign sc_forward_valid = i_reservation.lr_in_flight &&
    (i_reservation.lr_in_flight_addr[XLEN-1:2] == i_source_reg_1_value[XLEN-1:2]);
  // SC.W result: 0=success, 1=fail (this value goes to rd)
  assign o_sc_success = sc_reservation_valid | sc_forward_valid;

  // Generate write enables and align data based on store size
  always_comb begin
    // Generate per-byte write enables based on store size and byte offset.
    // Shift store data to align with correct byte lanes based on address offset.

    // Default data output (used by most store types)
    o_data_memory_write_data = i_source_reg_2_value;

    // Handle SC.W specially: write if reservation valid (or forwarded), otherwise no write
    if (i_is_sc) begin
      // SC.W: conditional word store based on reservation or forwarded LR
      o_data_memory_byte_write_enable = (sc_reservation_valid | sc_forward_valid) ? 4'b1111 :
                                                                                    4'b0000;
    end else begin
      unique case (i_store_operation)
        riscv_pkg::STB: begin  // Store byte (1 byte)
          o_data_memory_byte_write_enable = 4'b0001 << store_byte_offset;
          o_data_memory_write_data = i_source_reg_2_value << (8 * store_byte_offset);
        end
        riscv_pkg::STH: begin  // Store halfword (2 bytes)
          o_data_memory_byte_write_enable = 4'b0011 << {store_byte_offset[1], 1'b0};
          o_data_memory_write_data = i_source_reg_2_value << (8 * store_byte_offset);
        end
        riscv_pkg::STW: begin  // Store word (4 bytes)
          o_data_memory_byte_write_enable = 4'b1111;
        end
        riscv_pkg::STN: begin  // Store nothing (0 bytes)
          o_data_memory_byte_write_enable = 4'b0000;
        end
      endcase
    end
  end

endmodule : store_unit
