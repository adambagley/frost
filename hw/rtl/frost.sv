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
  Top-level module for the FROST RISC-V processor system. This module integrates a complete
  32-bit RISC-V processor core with dual-port memory, UART communication interface, and
  memory-mapped I/O (MMIO) FIFOs. The design features clock domain crossing between the main
  processor clock (i_clk) and a divided clock (i_clk_div4) used for JTAG and UART operations.
  The module includes reset synchronization, instruction memory interface for external programming
  via JTAG, and a debug UART output for printing. The system uses distributed RAM FIFOs for
  MMIO operations and dual-clock FIFOs for clock domain crossing (the clocks share a common
  source via MMCM, so Gray code pointers are unnecessary). All submodules use portable RTL
  without vendor-specific primitives, ensuring design portability across FPGA platforms.
  No xilinx IP or primitives from this module on down
*/
module frost #(
    parameter int unsigned CLK_FREQ_HZ = 322265625,
    // Timer speedup for simulation - multiplies mtime increment rate
    // Set to 1 for synthesis (normal behavior), higher for faster simulation
    // Example: 1000 makes FreeRTOS timers run 1000x faster in simulation
    parameter int unsigned SIM_TIMER_SPEEDUP = 1
) (
    input logic i_clk,
    input logic i_clk_div4,
    input logic i_rst_n,

    input  logic        i_instr_mem_en,
    input  logic [ 3:0] i_instr_mem_we,
    input  logic [31:0] i_instr_mem_addr,
    input  logic [31:0] i_instr_mem_wrdata,
    output logic [31:0] o_instr_mem_rddata,

    output logic o_uart_tx,
    input  logic i_uart_rx,

    // External interrupt input (directly triggers MEIP when high)
    // Optional: tie to 0 if not used
    input logic i_external_interrupt = 1'b0
);

  /*
    Reset synchronization chain for main clock domain.
    Converts asynchronous reset input (active-low) to synchronous reset (active-high).
    Uses multiple flip-flop stages to safely cross from async reset to sync domain.
    Potential TODO: have reset asserted async but deasserted sync for faster reset entry
  */
  localparam int unsigned NumResetSyncStages = 3;
  (* ASYNC_REG = "TRUE" *)
  logic [NumResetSyncStages-1:0] reset_synchronizer_shift_register;
  logic reset_synchronized;
  always_ff @(posedge i_clk)
    for (int i = 0; i < NumResetSyncStages; ++i)
      reset_synchronizer_shift_register[i] <= (i > 0) ?
                                              reset_synchronizer_shift_register[i-1] :
                                              ~i_rst_n;  // Invert: active-low input to active-high
  assign reset_synchronized = reset_synchronizer_shift_register[NumResetSyncStages-1];

  // Reset synchronization for divided clock domain (JTAG/UART clock)
  (* ASYNC_REG = "TRUE" *)
  logic [NumResetSyncStages-1:0] reset_div4_synchronizer_shift_register;
  logic reset_div4_synchronized;
  always_ff @(posedge i_clk_div4)
    for (int i = 0; i < NumResetSyncStages; ++i)
      reset_div4_synchronizer_shift_register[i] <= (i > 0) ?
                                                   reset_div4_synchronizer_shift_register[i-1] :
                                                   ~i_rst_n;
  assign reset_div4_synchronized = reset_div4_synchronizer_shift_register[NumResetSyncStages-1];

  /*
    UART write delay chain - adds pipeline stages to relax timing constraints.
    This intentionally trades latency for better placement/routing since UART is not timing-critical.
    The delay allows the synthesizer to place logic further apart, improving timing closure.
  */
  logic       uart_write_enable_from_cpu;
  logic [7:0] uart_write_data_from_cpu;
  localparam int unsigned NumUartDelayStages = 10;
  // Purposely use register style (not SRL primitive) to physically spread out delay chain
  (* srl_style = "register" *)logic [NumUartDelayStages-1:0]      uart_write_enable_delay_chain;
  (* srl_style = "register" *)logic [NumUartDelayStages-1:0][7:0] uart_write_data_delay_chain;
  always_ff @(posedge i_clk)
    for (int stage = 0; stage < NumUartDelayStages; ++stage) begin
      uart_write_enable_delay_chain[stage] <= (stage > 0) ?
                                              uart_write_enable_delay_chain[stage-1] :
                                              uart_write_enable_from_cpu;
      uart_write_data_delay_chain[stage] <= (stage > 0) ?
                                            uart_write_data_delay_chain[stage-1] :
                                            uart_write_data_from_cpu;
    end

  // Instruction memory interface signals after clock domain crossing from i_clk_div4 to i_clk
  // These signals come from JTAG interface for programming instruction memory
  logic        instruction_memory_enable_after_cdc;
  logic [ 3:0] instruction_memory_write_enable_after_cdc;
  logic [31:0] instruction_memory_address_after_cdc;
  logic [31:0] instruction_memory_write_data_after_cdc;

  // Dual-clock FIFO for instruction memory writes - crosses from JTAG clock domain (clk_div4) to CPU clock domain
  dc_fifo #(
      .DATA_WIDTH($bits(i_instr_mem_we) + $bits(i_instr_mem_addr) + $bits(i_instr_mem_wrdata)),
      // FIFO depth could potentially be reduced since read rate >> write rate
      .DEPTH(512)
  ) instruction_memory_clock_domain_crossing_fifo (
      .o_clk(i_clk),  // Output: main CPU clock
      .i_clk(i_clk_div4),  // Input: JTAG/programming clock
      /*
        Purposely don't reset this FIFO - it needs to remain active to write instruction
        memory while the rest of the system is held in reset during programming
      */
      .o_rst(1'b0),
      .i_rst(1'b0),
      .i_data({i_instr_mem_we, i_instr_mem_addr, i_instr_mem_wrdata}),
      .i_valid(i_instr_mem_en),
      .o_ready(),  // Not used - assume FIFO always has space
      .o_data({
        instruction_memory_write_enable_after_cdc,
        instruction_memory_address_after_cdc,
        instruction_memory_write_data_after_cdc
      }),
      .o_valid(instruction_memory_enable_after_cdc),
      .i_ready(1'b1)  // Always ready to accept
  );

  // UART RX interface signals - received data from UART to CPU
  logic        uart_rx_data_valid_to_cpu;
  logic [ 7:0] uart_rx_data_to_cpu;
  logic        uart_rx_data_ready_from_cpu;

  // Memory-mapped I/O FIFO interface signals for CPU peripheral communication
  logic        mmio_fifo0_write_enable;
  logic [31:0] mmio_fifo0_write_data;
  logic [31:0] mmio_fifo0_read_data;
  logic        mmio_fifo0_is_empty;
  logic        mmio_fifo0_is_full;
  logic        mmio_fifo0_read_enable;

  logic        mmio_fifo1_write_enable;
  logic [31:0] mmio_fifo1_write_data;
  logic [31:0] mmio_fifo1_read_data;
  logic        mmio_fifo1_is_empty;
  logic        mmio_fifo1_is_full;
  logic        mmio_fifo1_read_enable;

  // CPU and memory subsystem - contains processor core and unified instruction/data RAM
  cpu_and_mem #(
      .SIM_TIMER_SPEEDUP(SIM_TIMER_SPEEDUP)
  ) cpu_and_memory_subsystem (
      .i_clk,
      .i_rst(reset_synchronized),
      .i_instr_mem_en(instruction_memory_enable_after_cdc),
      .i_instr_mem_we(instruction_memory_write_enable_after_cdc),
      .i_instr_mem_addr(instruction_memory_address_after_cdc),
      .i_instr_mem_wrdata(instruction_memory_write_data_after_cdc),
      .o_instr_mem_rddata,
      .o_uart_wr_en(uart_write_enable_from_cpu),
      .o_uart_wr_data(uart_write_data_from_cpu),
      // UART RX interface
      .i_uart_rx_data(uart_rx_data_to_cpu),
      .i_uart_rx_valid(uart_rx_data_valid_to_cpu),
      .o_uart_rx_ready(uart_rx_data_ready_from_cpu),
      // MMIO FIFO 0 interface
      .o_fifo0_wr_en(mmio_fifo0_write_enable),
      .o_fifo0_wr_data(mmio_fifo0_write_data),
      .i_fifo0_rd_data(mmio_fifo0_read_data),
      .i_fifo0_empty(mmio_fifo0_is_empty),
      .o_fifo0_rd_en(mmio_fifo0_read_enable),
      // MMIO FIFO 1 interface
      .o_fifo1_wr_en(mmio_fifo1_write_enable),
      .o_fifo1_wr_data(mmio_fifo1_write_data),
      .i_fifo1_rd_data(mmio_fifo1_read_data),
      .i_fifo1_empty(mmio_fifo1_is_empty),
      .o_fifo1_rd_en(mmio_fifo1_read_enable),
      // External interrupt (directly triggers machine external interrupt)
      .i_external_interrupt(i_external_interrupt)
  );

  // Memory-mapped I/O FIFO 0 - used for general-purpose data buffering
  sync_dist_ram_fifo #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(9)    // 512 entries deep
  ) memory_mapped_io_fifo_0 (
      .i_clk,
      .i_rst(reset_synchronized),
      // Purposely ignore full signal for better timing (assume software manages overflow)
      .i_write_enable(mmio_fifo0_write_enable),
      .i_read_enable(mmio_fifo0_read_enable),
      .i_write_data(mmio_fifo0_write_data),
      .o_read_data(mmio_fifo0_read_data),
      .o_empty(mmio_fifo0_is_empty),
      .o_full(mmio_fifo0_is_full)
  );

  // Memory-mapped I/O FIFO 1 - used for general-purpose data buffering
  sync_dist_ram_fifo #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(9)    // 512 entries deep
  ) memory_mapped_io_fifo_1 (
      .i_clk,
      .i_rst(reset_synchronized),
      // Purposely ignore full signal for better timing (assume software manages overflow)
      .i_write_enable(mmio_fifo1_write_enable),
      .i_read_enable(mmio_fifo1_read_enable),
      .i_write_data(mmio_fifo1_write_data),
      .o_read_data(mmio_fifo1_read_data),
      .o_empty(mmio_fifo1_is_empty),
      .o_full(mmio_fifo1_is_full)
  );

  // Interface signals for UART transmitter module
  logic [7:0] uart_fifo_data;
  logic       uart_fifo_valid;
  logic       uart_fifo_ready;

  /*
    Dual-clock FIFO for UART data - crosses from CPU clock domain to UART clock domain (clk_div4)
    Buffers print data from CPU before transmission over slower UART serial interface.
    This enables the fast CPU to continue execution while UART sends data at baud rate.
  */
  dc_fifo #(
      .DATA_WIDTH(8)  // 8 bits per UART character
  ) uart_transmit_clock_domain_crossing_fifo (
      .o_clk(i_clk_div4),  // Output: UART clock domain (slow)
      .i_clk(i_clk),  // Input: CPU clock domain (fast)
      .o_rst(reset_div4_synchronized),
      .i_rst(reset_synchronized),
      .i_data(uart_write_data_delay_chain[NumUartDelayStages-1]),
      .i_valid(uart_write_enable_delay_chain[NumUartDelayStages-1]),
      .o_ready(),  // Not used - assume FIFO has sufficient depth
      .o_data(uart_fifo_data),
      .o_valid(uart_fifo_valid),
      .i_ready(uart_fifo_ready)
  );

  // UART transmitter - converts valid/ready handshake to serial UART protocol
  uart_tx #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ / 4),  // UART runs on divided clock
      .BAUD_RATE(115200)  // Standard baud rate for console communication
  ) uart_transmitter (
      .i_clk  (i_clk_div4),
      .i_rst  (reset_div4_synchronized),
      .i_data (uart_fifo_data),
      .i_valid(uart_fifo_valid),
      .o_ready(uart_fifo_ready),
      .o_uart (o_uart_tx)
  );

  /*
    UART RX subsystem - receives serial data and crosses to CPU clock domain.
    The uart_rx module runs in the clk_div4 domain (same as TX for consistent baud rate).
    A dual-clock FIFO transfers received bytes to the CPU clock domain for MMIO reads.
  */

  // Interface signals for UART receiver module
  logic [7:0] uart_rx_data_from_receiver;
  logic       uart_rx_valid_from_receiver;
  logic       uart_rx_ready_to_receiver;

  // UART receiver - converts serial UART protocol to valid/ready handshake
  uart_rx #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ / 4),  // UART runs on divided clock
      .BAUD_RATE(115200)  // Standard baud rate for console communication
  ) uart_receiver (
      .i_clk  (i_clk_div4),
      .i_rst  (reset_div4_synchronized),
      .i_uart (i_uart_rx),
      .o_data (uart_rx_data_from_receiver),
      .o_valid(uart_rx_valid_from_receiver),
      .i_ready(uart_rx_ready_to_receiver)
  );

  /*
    Dual-clock FIFO for UART RX data - crosses from UART clock domain to CPU clock domain.
    Buffers received data from slow UART serial interface before CPU reads it via MMIO.
    This allows the UART to continue receiving while CPU processes previous data.
  */
  dc_fifo #(
      .DATA_WIDTH(8)  // 8 bits per UART character
  ) uart_receive_clock_domain_crossing_fifo (
      .i_clk(i_clk_div4),  // Input: UART clock domain (slow)
      .o_clk(i_clk),  // Output: CPU clock domain (fast)
      .i_rst(reset_div4_synchronized),
      .o_rst(reset_synchronized),
      .i_data(uart_rx_data_from_receiver),
      .i_valid(uart_rx_valid_from_receiver),
      .o_ready(uart_rx_ready_to_receiver),
      .o_data(uart_rx_data_to_cpu),
      .o_valid(uart_rx_data_valid_to_cpu),
      .i_ready(uart_rx_data_ready_from_cpu)
  );

endmodule : frost
