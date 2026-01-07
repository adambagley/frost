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
  RISC-V register file with 32 general-purpose registers.
  Implements a triple-ported register file with two simultaneous read ports and one
  write port, essential for single-cycle instruction execution in the pipeline.
  The design uses two instances of dual-port distributed RAM to achieve three ports -
  both RAMs share the same write port but have independent read ports for rs1 and rs2.
  Register x0 is hardwired to zero per RISC-V specification (handled by CPU logic).

  Read addresses come from PD stage (early source registers) so the regfile read
  happens in ID stage. The read data is then registered at the ID→EX boundary,
  moving the RAM read out of the EX stage critical path.
*/
// RISC-V register file using tri-port distributed RAM (2 read ports, 1 write port)
// Provides simultaneous reads of two source registers (rs1, rs2) and write to destination (rd)
module regfile #(
    parameter int unsigned DEPTH = 32,  // Number of registers (32 for RV32)
    parameter int unsigned DATA_WIDTH = 32  // Register width in bits
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id, // Read address from PD stage (early src regs)
    input riscv_pkg::from_ma_to_wb_t i_from_ma_to_wb,
    output riscv_pkg::rf_to_fwd_t o_rf_to_fwd
);

  // First RAM instance: provides rs1 read port, shares write port
  // Read address uses early source regs from PD stage (registered at PD→ID boundary)
  // so the RAM read occurs in ID stage, not EX stage
  sdp_dist_ram #(
      .ADDR_WIDTH($clog2(DEPTH)),
      .DATA_WIDTH(DATA_WIDTH)
  ) source_register_1_ram (
      .i_clk,
      // Write enable: only if instruction writes, destination is not x0, and pipeline not stalled
      .i_write_enable(i_from_ma_to_wb.regfile_write_enable &
                      ~i_pipeline_ctrl.stall &
                      |i_from_ma_to_wb.instruction.dest_reg),
      .i_write_address(i_from_ma_to_wb.instruction.dest_reg),
      .i_write_data(i_from_ma_to_wb.regfile_write_data),
      .i_read_address(i_from_pd_to_id.source_reg_1_early),
      .o_read_data(o_rf_to_fwd.source_reg_1_data)
  );

  // Second RAM instance: provides rs2 read port, shares write port
  sdp_dist_ram #(
      .ADDR_WIDTH($clog2(DEPTH)),
      .DATA_WIDTH(DATA_WIDTH)
  ) source_register_2_ram (
      .i_clk,
      // Write enable: same logic as source_register_1_ram
      .i_write_enable(i_from_ma_to_wb.regfile_write_enable &
                      ~i_pipeline_ctrl.stall &
                      |i_from_ma_to_wb.instruction.dest_reg),
      .i_write_address(i_from_ma_to_wb.instruction.dest_reg),
      .i_write_data(i_from_ma_to_wb.regfile_write_data),
      .i_read_address(i_from_pd_to_id.source_reg_2_early),
      .o_read_data(o_rf_to_fwd.source_reg_2_data)
  );

endmodule : regfile
