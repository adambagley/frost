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

// Top-level module for Nexys A7 FPGA board integration
// Handles Artix-7 specific clock generation and instantiates common subsystem
module nexys_a7_frost (
    input logic i_sysclk,  // Single-ended system clock (100 MHz)

    input logic i_pb_resetn,  // Push-button reset (active-low)

    output logic o_uart_tx,  // UART transmit for debug console
    input  logic i_uart_rx   // UART receive for debug console input
);

  // Clock generation using Xilinx MMCM primitive
  logic main_clock, divided_clock_by_4;
  logic clock_100mhz_buffered, clock_feedback, clock_from_mmcm, clock_div4_from_mmcm;

  // Buffer the single-ended clock input
  IBUF clock_input_buffer (
      .I(i_sysclk),
      .O(clock_100mhz_buffered)
  );

  // Mixed-Mode Clock Manager (MMCM) for PLL-based clock generation
  MMCME2_ADV #(
      .CLKIN1_PERIOD   (10.000),  // Input period: 1/100MHz = 10ns
      .DIVCLK_DIVIDE   (1),       // Pre-divider: 100MHz / 1 = 100MHz
      // VCO (Voltage Controlled Oscillator) frequency: 100MHz * 8 = 800 MHz
      .CLKFBOUT_MULT_F (8.0),
      // Output clock 0: 800MHz / 10 = 80 MHz for FROST CPU (Artix-7 -1 is slower than Kintex-7 -2)
      .CLKOUT0_DIVIDE_F(10.0),
      // Output clock 1: 800MHz / 40 = 20 MHz (div4 for JTAG/UART)
      .CLKOUT1_DIVIDE  (40)
  ) mixed_mode_clock_manager (
      .CLKIN1  (clock_100mhz_buffered),
      .CLKFBIN (clock_feedback),
      .CLKFBOUT(clock_feedback),
      .CLKOUT0 (clock_from_mmcm),
      .CLKOUT1 (clock_div4_from_mmcm),
      .RST     (1'b0),                   // Don't reset MMCM
      .PWRDWN  (1'b0),                   // Don't power down
      .CLKIN2  (1'b0),
      .CLKINSEL(1'b1),                   // Select CLKIN1
      .LOCKED  (  /*not connected*/)
  );

  // Global clock buffer for low-skew distribution
  BUFG global_clock_buffer (
      .I(clock_from_mmcm),
      .O(main_clock)
  );

  // Global clock buffer for divided clock (JTAG/UART)
  BUFG divided_clock_buffer (
      .I(clock_div4_from_mmcm),
      .O(divided_clock_by_4)
  );

  // Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
  // Clock: 100MHz * 8 / 10 = 80 MHz
  xilinx_frost_subsystem #(
      .CLK_FREQ_HZ(80000000)
  ) subsystem (
      .i_clk(main_clock),
      .i_clk_div4(divided_clock_by_4),
      .i_rst_n(i_pb_resetn),
      .o_uart_tx,
      .i_uart_rx
  );

endmodule : nexys_a7_frost
