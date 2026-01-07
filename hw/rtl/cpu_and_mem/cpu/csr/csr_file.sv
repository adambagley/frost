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
  CSR (Control and Status Register) File for RISC-V Zicsr + Zicntr + Machine-mode extensions.

  This module implements:

  Zicntr base counters (read-only):
    - cycle/cycleh (0xC00/0xC80): Clock cycle counter (64-bit)
    - time/timeh (0xC01/0xC81): Wall-clock time (from mtime input)
    - instret/instreth (0xC02/0xC82): Instructions retired counter (64-bit)

  Machine-mode CSRs (for trap/interrupt handling):
    - mstatus (0x300): Machine status (MIE, MPIE bits)
    - misa (0x301): Machine ISA (read-only, reports RV32IMAB)
    - mie (0x304): Machine interrupt enable (MEIE, MTIE, MSIE)
    - mtvec (0x305): Machine trap vector base address
    - mscratch (0x340): Machine scratch register
    - mepc (0x341): Machine exception PC
    - mcause (0x342): Machine trap cause
    - mtval (0x343): Machine trap value
    - mip (0x344): Machine interrupt pending (read-only, directly wired to inputs)

  The module supports all six Zicsr instructions:
    - CSRRW/CSRRWI: Atomic read/write
    - CSRRS/CSRRSI: Atomic read and set bits
    - CSRRC/CSRRCI: Atomic read and clear bits
*/
module csr_file #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,

    // CSR access interface (directly from ID/EX stage)
    input  logic            i_csr_read_enable,   // CSR instruction in EX stage
    input  logic [    11:0] i_csr_address,       // CSR address
    input  logic [     2:0] i_csr_op,            // CSR operation (funct3)
    input  logic [XLEN-1:0] i_csr_write_data,    // rs1 value or zero-extended immediate
    input  logic            i_csr_write_enable,  // Actually perform write (not stalled/flushed)
    output logic [XLEN-1:0] o_csr_read_data,     // CSR read value

    // Instruction retire signal (active when instruction commits)
    input logic i_instruction_retired,

    // Interrupt pending inputs (directly from peripherals)
    input riscv_pkg::interrupt_t i_interrupts,

    // mtime input (from memory-mapped timer)
    input logic [63:0] i_mtime,

    // Trap entry signals (from trap unit)
    input logic            i_trap_taken,  // Trap is being taken
    input logic [XLEN-1:0] i_trap_pc,     // PC to save to mepc
    input logic [XLEN-1:0] i_trap_cause,  // Cause to save to mcause
    input logic [XLEN-1:0] i_trap_value,  // Value to save to mtval

    // MRET signal (from trap unit)
    input logic i_mret_taken,  // MRET is being executed

    // CSR outputs for trap/interrupt handling
    output logic [XLEN-1:0] o_mstatus,
    output logic [XLEN-1:0] o_mie,
    output logic [XLEN-1:0] o_mtvec,
    output logic [XLEN-1:0] o_mepc,

    // Direct output of mstatus MIE bit to avoid Icarus concatenation issues
    output logic o_mstatus_mie_direct
);

  // ==========================================================================
  // CSR Registers
  // ==========================================================================

  // 64-bit counters for Zicntr
  logic [    63:0] cycle_counter;
  logic [    63:0] instret_counter;

  // Machine-mode CSRs
  // mstatus: store MIE and MPIE as separate registers to work around Icarus Verilog issues
  // Icarus has problems with bit manipulation in always_ff blocks, so we use separate registers
  logic            mstatus_mie;  // Machine Interrupt Enable (bit 3)
  logic            mstatus_mpie;  // Machine Previous Interrupt Enable (bit 7)
  logic [XLEN-1:0] mstatus;  // Constructed from mie and mpie
  assign mstatus = {24'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};

  // mie CSR: store each interrupt enable as separate register
  logic mie_msie;  // Machine Software Interrupt Enable (bit 3)
  logic mie_mtie;  // Machine Timer Interrupt Enable (bit 7)
  logic mie_meie;  // Machine External Interrupt Enable (bit 11)
  logic [XLEN-1:0] mie;  // Constructed from individual enables
  assign mie = {20'b0, mie_meie, 3'b0, mie_mtie, 3'b0, mie_msie, 3'b0};

  // Next-state signals for mstatus bits (computed combinationally)
  logic next_mstatus_mie;
  logic next_mstatus_mpie;
  // Next-state signals for mie bits
  logic next_mie_msie;
  logic next_mie_mtie;
  logic next_mie_meie;

  logic [XLEN-1:0] mtvec;  // Trap vector base (MODE in bits [1:0], BASE in [31:2])
  logic [XLEN-1:0] mscratch;  // Scratch register for trap handlers
  logic [XLEN-1:0] mepc;  // Exception PC
  logic [XLEN-1:0] mcause;  // Trap cause
  logic [XLEN-1:0] mtval;  // Trap value

  // mip is read-only and directly reflects interrupt inputs
  logic [XLEN-1:0] mip;
  assign mip = {20'b0, i_interrupts.meip, 3'b0, i_interrupts.mtip, 3'b0, i_interrupts.msip, 3'b0};

  // misa is read-only: RV32IMAB
  // Bit 0 (A), Bit 1 (B), Bit 8 (I), Bit 12 (M) = 0x0000_1103
  // MXL = 1 (32-bit) in bits [31:30]
  localparam logic [XLEN-1:0] MisaValue = 32'h4000_1103;

  // Output CSRs for trap unit
  assign o_mstatus = mstatus;
  assign o_mie = mie;
  assign o_mtvec = mtvec;
  assign o_mepc = mepc;

  // Direct output of mstatus_mie register - bypasses concatenation for Icarus compatibility
  assign o_mstatus_mie_direct = mstatus_mie;

  // ==========================================================================
  // CSR Write Data Calculation
  // ==========================================================================

  logic [XLEN-1:0] csr_current_value;
  logic [XLEN-1:0] csr_new_value;

  // Get current value of addressed CSR (for read-modify-write operations)
  always_comb begin
    csr_current_value = '0;
    unique case (i_csr_address)
      riscv_pkg::CsrMstatus:  csr_current_value = mstatus;
      riscv_pkg::CsrMie:      csr_current_value = mie;
      riscv_pkg::CsrMtvec:    csr_current_value = mtvec;
      riscv_pkg::CsrMscratch: csr_current_value = mscratch;
      riscv_pkg::CsrMepc:     csr_current_value = mepc;
      riscv_pkg::CsrMcause:   csr_current_value = mcause;
      riscv_pkg::CsrMtval:    csr_current_value = mtval;
      default:                csr_current_value = '0;
    endcase
  end

  // Calculate new value based on CSR operation
  always_comb begin
    csr_new_value = csr_current_value;
    unique case (i_csr_op)
      riscv_pkg::CSR_RW, riscv_pkg::CSR_RWI: csr_new_value = i_csr_write_data;
      riscv_pkg::CSR_RS, riscv_pkg::CSR_RSI: csr_new_value = csr_current_value | i_csr_write_data;
      riscv_pkg::CSR_RC, riscv_pkg::CSR_RCI: csr_new_value = csr_current_value & ~i_csr_write_data;
      default:                               csr_new_value = csr_current_value;
    endcase
  end

  // ==========================================================================
  // Cycle Counter
  // ==========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      cycle_counter <= 64'd0;
    end else begin
      cycle_counter <= cycle_counter + 64'd1;
    end
  end

  // ==========================================================================
  // Instructions Retired Counter
  // ==========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      instret_counter <= 64'd0;
    end else if (i_instruction_retired) begin
      instret_counter <= instret_counter + 64'd1;
    end
  end

  // ==========================================================================
  // Machine-Mode CSR Updates - Next-State Logic
  // ==========================================================================

  // Compute next-state values for mstatus/mie bits in a combinational block.
  // This works around Icarus Verilog issues with conditional assignments in always_ff.
  // The always block below just registers these values unconditionally.
  // Note: Using always @(*) instead of always_comb for Icarus compatibility.

  always_comb begin
    // Default: keep current values
    next_mstatus_mie = mstatus_mie;
    next_mstatus_mpie = mstatus_mpie;
    next_mie_msie = mie_msie;
    next_mie_mtie = mie_mtie;
    next_mie_meie = mie_meie;

    if (i_trap_taken) begin
      // Trap entry: save MIE to MPIE, clear MIE
      next_mstatus_mpie = mstatus_mie;
      next_mstatus_mie  = 1'b0;
    end else if (i_mret_taken) begin
      // MRET: restore MIE from MPIE, set MPIE to 1
      next_mstatus_mie  = mstatus_mpie;
      next_mstatus_mpie = 1'b1;
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      if (i_csr_address == riscv_pkg::CsrMstatus) begin
        next_mstatus_mie  = csr_new_value[3];
        next_mstatus_mpie = csr_new_value[7];
      end else if (i_csr_address == riscv_pkg::CsrMie) begin
        next_mie_msie = csr_new_value[3];
        next_mie_mtie = csr_new_value[7];
        next_mie_meie = csr_new_value[11];
      end
    end
  end

  // Simple flip-flops for mstatus/mie bits - using old-style always for Icarus compatibility
  // Note: Using always @(posedge) instead of always_ff as a workaround for Icarus issues
  always @(posedge i_clk) begin
    if (i_rst) begin
      mstatus_mie <= 1'b0;
      mstatus_mpie <= 1'b0;
      mie_msie <= 1'b0;
      mie_mtie <= 1'b0;
      mie_meie <= 1'b0;
    end else begin
      mstatus_mie <= next_mstatus_mie;
      mstatus_mpie <= next_mstatus_mpie;
      mie_msie <= next_mie_msie;
      mie_mtie <= next_mie_mtie;
      mie_meie <= next_mie_meie;
    end
  end

  // ==========================================================================
  // Other Machine-Mode CSR Updates
  // ==========================================================================

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mtvec    <= 32'h0000_0000;
      mscratch <= 32'h0000_0000;
      mepc     <= 32'h0000_0000;
      mcause   <= 32'h0000_0000;
      mtval    <= 32'h0000_0000;
    end else if (i_trap_taken) begin
      // Trap entry: save state
      mepc   <= i_trap_pc;
      mcause <= i_trap_cause;
      mtval  <= i_trap_value;
    end else if (i_csr_write_enable && i_csr_read_enable) begin
      unique case (i_csr_address)
        riscv_pkg::CsrMtvec: mtvec <= {csr_new_value[XLEN-1:2], 2'b00};
        riscv_pkg::CsrMscratch: mscratch <= csr_new_value;
        riscv_pkg::CsrMepc: mepc <= {csr_new_value[XLEN-1:1], 1'b0};  // 2-byte aligned for C ext
        riscv_pkg::CsrMcause: mcause <= csr_new_value;
        riscv_pkg::CsrMtval: mtval <= csr_new_value;
        default: ;
      endcase
    end
  end

  // ==========================================================================
  // CSR Read Multiplexer
  // ==========================================================================

  always_comb begin
    o_csr_read_data = '0;  // Default: return 0 for non-implemented CSRs

    if (i_csr_read_enable) begin
      unique case (i_csr_address)
        // Zicntr counters (read-only)
        riscv_pkg::CsrCycle: o_csr_read_data = cycle_counter[31:0];
        riscv_pkg::CsrCycleH: o_csr_read_data = cycle_counter[63:32];
        riscv_pkg::CsrTime: o_csr_read_data = i_mtime[31:0];
        riscv_pkg::CsrTimeH: o_csr_read_data = i_mtime[63:32];
        riscv_pkg::CsrInstret: o_csr_read_data = instret_counter[31:0];
        riscv_pkg::CsrInstretH: o_csr_read_data = instret_counter[63:32];
        // Machine-mode CSRs
        riscv_pkg::CsrMstatus: o_csr_read_data = mstatus;
        riscv_pkg::CsrMisa: o_csr_read_data = MisaValue;
        riscv_pkg::CsrMie: o_csr_read_data = mie;
        riscv_pkg::CsrMtvec: o_csr_read_data = mtvec;
        riscv_pkg::CsrMscratch: o_csr_read_data = mscratch;
        riscv_pkg::CsrMepc: o_csr_read_data = mepc;
        riscv_pkg::CsrMcause: o_csr_read_data = mcause;
        riscv_pkg::CsrMtval: o_csr_read_data = mtval;
        riscv_pkg::CsrMip: o_csr_read_data = mip;
        // Machine information registers (read-only)
        riscv_pkg::CsrMhartid:
        o_csr_read_data = '0;  // Hardware thread ID (always 0 for single-core)
        default: o_csr_read_data = '0;
      endcase
    end
  end

endmodule : csr_file
