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
  RISC-V Compressed (RVC) instruction decompressor.
  Expands 16-bit compressed instructions into their 32-bit equivalents.

  The C extension uses three quadrants based on bits [1:0]:
  - Quadrant 0 (00): Stack-relative loads/stores, wide immediates
  - Quadrant 1 (01): Control flow, arithmetic, immediates
  - Quadrant 2 (10): Register ops, stack-pointer-relative ops
  - Quadrant 3 (11): Not compressed (32-bit instruction)

  Compressed registers (3-bit) map to x8-x15: reg' = {2'b01, 3-bit-value}

  Timing optimization: Uses parallel decode with one-hot selection mux
  instead of nested case statements. All instruction expansions are
  computed in parallel, then selected via flat one-hot OR structure.
*/
module rvc_decompressor (
    input  logic [15:0] i_instr_compressed,
    output logic [31:0] o_instr_expanded,
    output logic        o_is_compressed,
    output logic        o_illegal
);

  // Extract common fields from compressed instruction
  logic [1:0] quadrant;
  logic [2:0] funct3;

  assign quadrant = i_instr_compressed[1:0];
  assign funct3 = i_instr_compressed[15:13];

  // Instruction is compressed if bits [1:0] != 2'b11
  assign o_is_compressed = (quadrant != 2'b11);

  // Standard RISC-V opcodes for expansion
  localparam logic [6:0] OpcLui = 7'b0110111;
  localparam logic [6:0] OpcJal = 7'b1101111;
  localparam logic [6:0] OpcJalr = 7'b1100111;
  localparam logic [6:0] OpcBranch = 7'b1100011;
  localparam logic [6:0] OpcLoad = 7'b0000011;
  localparam logic [6:0] OpcStore = 7'b0100011;
  localparam logic [6:0] OpcOpImm = 7'b0010011;
  localparam logic [6:0] OpcOp = 7'b0110011;

  // ===========================================================================
  // Pre-compute register fields (used across multiple instructions)
  // ===========================================================================
  logic [4:0] rd_full, rs1_full, rs2_full;  // Full 5-bit register specifiers
  logic [4:0] rd_prime, rs1_prime, rs2_prime;  // Compressed reg -> x8-x15

  assign rd_full   = i_instr_compressed[11:7];
  assign rs1_full  = i_instr_compressed[11:7];  // Same bits for C2 quadrant
  assign rs2_full  = i_instr_compressed[6:2];
  assign rd_prime  = {2'b01, i_instr_compressed[4:2]};  // x8-x15
  assign rs1_prime = {2'b01, i_instr_compressed[9:7]};  // x8-x15
  assign rs2_prime = {2'b01, i_instr_compressed[4:2]};  // x8-x15

  // ===========================================================================
  // Pre-compute ALL immediates in parallel
  // ===========================================================================

  // C.ADDI4SPN: nzuimm[5:4|9:6|2|3] from bits [12:5], scaled by 4
  logic [11:0] imm_addi4spn;
  assign imm_addi4spn = {
    2'b0,
    i_instr_compressed[10:7],
    i_instr_compressed[12:11],
    i_instr_compressed[5],
    i_instr_compressed[6],
    2'b00
  };

  // C.LW/C.SW: uimm[5:3|2|6] from bits [12:10,6,5], scaled by 4
  logic [11:0] imm_lw_sw;
  assign imm_lw_sw = {
    5'b0, i_instr_compressed[5], i_instr_compressed[12:10], i_instr_compressed[6], 2'b00
  };

  // C.ADDI/C.LI/C.ANDI: 6-bit sign-extended immediate
  logic [11:0] imm_ci;
  assign imm_ci = {{6{i_instr_compressed[12]}}, i_instr_compressed[12], i_instr_compressed[6:2]};

  // C.ADDI16SP: nzimm[9|4|6|8:7|5] from bits [12,6:2], scaled by 16
  logic [11:0] imm_addi16sp;
  assign imm_addi16sp = {
    {2{i_instr_compressed[12]}},
    i_instr_compressed[12],
    i_instr_compressed[4:3],
    i_instr_compressed[5],
    i_instr_compressed[2],
    i_instr_compressed[6],
    4'b0000
  };

  // C.LUI: 6-bit immediate for upper bits (sign-extended)
  logic [19:0] imm_lui;
  assign imm_lui = {{14{i_instr_compressed[12]}}, i_instr_compressed[12], i_instr_compressed[6:2]};

  // C.J/C.JAL: 12-bit jump offset
  logic [11:0] imm_j;
  assign imm_j = {
    i_instr_compressed[12],
    i_instr_compressed[8],
    i_instr_compressed[10:9],
    i_instr_compressed[6],
    i_instr_compressed[7],
    i_instr_compressed[2],
    i_instr_compressed[11],
    i_instr_compressed[5:3],
    1'b0
  };

  // C.BEQZ/C.BNEZ: 9-bit branch offset
  logic [8:0] imm_b;
  assign imm_b = {
    i_instr_compressed[12],
    i_instr_compressed[6:5],
    i_instr_compressed[2],
    i_instr_compressed[11:10],
    i_instr_compressed[4:3],
    1'b0
  };

  // C.LWSP: uimm[5|4:2|7:6] from bits [12,6:2], scaled by 4
  logic [11:0] imm_lwsp;
  assign imm_lwsp = {
    4'b0, i_instr_compressed[3:2], i_instr_compressed[12], i_instr_compressed[6:4], 2'b00
  };

  // C.SWSP: uimm[5:2|7:6] from bits [12:7], scaled by 4
  logic [7:0] imm_swsp;
  assign imm_swsp = {i_instr_compressed[8:7], i_instr_compressed[12:9], 2'b00};

  // Shift amount (5-bit for RV32)
  logic [4:0] shamt;
  assign shamt = i_instr_compressed[6:2];

  // ===========================================================================
  // Pre-compute ALL instruction expansions in parallel
  // ===========================================================================

  logic [31:0] instr_addi4spn;  // C.ADDI4SPN
  logic [31:0] instr_lw;  // C.LW
  logic [31:0] instr_sw;  // C.SW
  logic [31:0] instr_addi;  // C.ADDI / C.NOP
  logic [31:0] instr_jal;  // C.JAL
  logic [31:0] instr_li;  // C.LI
  logic [31:0] instr_addi16sp;  // C.ADDI16SP
  logic [31:0] instr_lui;  // C.LUI
  logic [31:0] instr_srli;  // C.SRLI
  logic [31:0] instr_srai;  // C.SRAI
  logic [31:0] instr_andi;  // C.ANDI
  logic [31:0] instr_sub;  // C.SUB
  logic [31:0] instr_xor;  // C.XOR
  logic [31:0] instr_or;  // C.OR
  logic [31:0] instr_and;  // C.AND
  logic [31:0] instr_j;  // C.J
  logic [31:0] instr_beqz;  // C.BEQZ
  logic [31:0] instr_bnez;  // C.BNEZ
  logic [31:0] instr_slli;  // C.SLLI
  logic [31:0] instr_lwsp;  // C.LWSP
  logic [31:0] instr_jr;  // C.JR
  logic [31:0] instr_mv;  // C.MV
  logic [31:0] instr_ebreak;  // C.EBREAK
  logic [31:0] instr_jalr;  // C.JALR
  logic [31:0] instr_add;  // C.ADD
  logic [31:0] instr_swsp;  // C.SWSP

  // Quadrant 0 instructions
  assign instr_addi4spn = {imm_addi4spn, 5'd2, 3'b000, rd_prime, OpcOpImm};
  assign instr_lw = {imm_lw_sw, rs1_prime, 3'b010, rd_prime, OpcLoad};
  assign instr_sw = {imm_lw_sw[11:5], rs2_prime, rs1_prime, 3'b010, imm_lw_sw[4:0], OpcStore};

  // Quadrant 1 instructions
  assign instr_addi = {imm_ci, rd_full, 3'b000, rd_full, OpcOpImm};
  assign instr_jal = {imm_j[11], imm_j[10:1], imm_j[11], {8{imm_j[11]}}, 5'd1, OpcJal};
  assign instr_li = {imm_ci, 5'd0, 3'b000, rd_full, OpcOpImm};
  assign instr_addi16sp = {imm_addi16sp, 5'd2, 3'b000, 5'd2, OpcOpImm};
  assign instr_lui = {imm_lui, rd_full, OpcLui};
  assign instr_srli = {7'b0000000, shamt, rs1_prime, 3'b101, rs1_prime, OpcOpImm};
  assign instr_srai = {7'b0100000, shamt, rs1_prime, 3'b101, rs1_prime, OpcOpImm};
  assign instr_andi = {imm_ci, rs1_prime, 3'b111, rs1_prime, OpcOpImm};
  assign instr_sub = {7'b0100000, rs2_prime, rs1_prime, 3'b000, rs1_prime, OpcOp};
  assign instr_xor = {7'b0000000, rs2_prime, rs1_prime, 3'b100, rs1_prime, OpcOp};
  assign instr_or = {7'b0000000, rs2_prime, rs1_prime, 3'b110, rs1_prime, OpcOp};
  assign instr_and = {7'b0000000, rs2_prime, rs1_prime, 3'b111, rs1_prime, OpcOp};
  assign instr_j = {imm_j[11], imm_j[10:1], imm_j[11], {8{imm_j[11]}}, 5'd0, OpcJal};
  assign instr_beqz = {
    imm_b[8], {3{imm_b[8]}}, imm_b[7:5], 5'd0, rs1_prime, 3'b000, imm_b[4:1], imm_b[8], OpcBranch
  };
  assign instr_bnez = {
    imm_b[8], {3{imm_b[8]}}, imm_b[7:5], 5'd0, rs1_prime, 3'b001, imm_b[4:1], imm_b[8], OpcBranch
  };

  // Quadrant 2 instructions
  assign instr_slli = {7'b0000000, shamt, rd_full, 3'b001, rd_full, OpcOpImm};
  assign instr_lwsp = {imm_lwsp, 5'd2, 3'b010, rd_full, OpcLoad};
  assign instr_jr = {12'b0, rs1_full, 3'b000, 5'd0, OpcJalr};
  assign instr_mv = {7'b0, rs2_full, 5'd0, 3'b000, rd_full, OpcOp};
  assign instr_ebreak = 32'h0010_0073;
  assign instr_jalr = {12'b0, rs1_full, 3'b000, 5'd1, OpcJalr};
  assign instr_add = {7'b0, rs2_full, rd_full, 3'b000, rd_full, OpcOp};
  assign instr_swsp = {4'b0, imm_swsp[7:5], rs2_full, 5'd2, 3'b010, imm_swsp[4:0], OpcStore};

  // ===========================================================================
  // Compute one-hot select signals in parallel
  // ===========================================================================
  logic sel_addi4spn, sel_lw, sel_sw;
  logic sel_addi, sel_jal, sel_li, sel_addi16sp, sel_lui;
  logic sel_srli, sel_srai, sel_andi, sel_sub, sel_xor, sel_or, sel_and;
  logic sel_j, sel_beqz, sel_bnez;
  logic sel_slli, sel_lwsp, sel_jr, sel_mv, sel_ebreak, sel_jalr, sel_add, sel_swsp;
  logic sel_passthrough;

  // Helper signals for Quadrant 1 funct3=100 sub-decoding
  logic q1_f100;  // Quadrant 1, funct3 = 100
  logic [1:0] q1_f100_type;  // bits [11:10]
  logic q1_f100_is_alu;  // type = 11 (register-register ALU ops)
  logic [1:0] q1_f100_alu_op;  // bits [6:5] for SUB/XOR/OR/AND

  assign q1_f100 = (quadrant == 2'b01) && (funct3 == 3'b100);
  assign q1_f100_type = i_instr_compressed[11:10];
  assign q1_f100_is_alu = q1_f100 && (q1_f100_type == 2'b11) && !i_instr_compressed[12];
  assign q1_f100_alu_op = i_instr_compressed[6:5];

  // Helper for Quadrant 2 funct3=100 sub-decoding
  logic q2_f100;
  logic q2_f100_bit12;

  assign q2_f100 = (quadrant == 2'b10) && (funct3 == 3'b100);
  assign q2_f100_bit12 = i_instr_compressed[12];

  // Quadrant 0 selects
  assign sel_addi4spn = (quadrant == 2'b00) && (funct3 == 3'b000);
  assign sel_lw = (quadrant == 2'b00) && (funct3 == 3'b010);
  assign sel_sw = (quadrant == 2'b00) && (funct3 == 3'b110);

  // Quadrant 1 selects
  assign sel_addi = (quadrant == 2'b01) && (funct3 == 3'b000);
  assign sel_jal = (quadrant == 2'b01) && (funct3 == 3'b001);
  assign sel_li = (quadrant == 2'b01) && (funct3 == 3'b010);
  assign sel_addi16sp = (quadrant == 2'b01) && (funct3 == 3'b011) && (rd_full == 5'd2);
  assign sel_lui = (quadrant == 2'b01) && (funct3 == 3'b011) && (rd_full != 5'd2) &&
                                                                (rd_full != 5'd0);
  assign sel_srli = q1_f100 && (q1_f100_type == 2'b00);
  assign sel_srai = q1_f100 && (q1_f100_type == 2'b01);
  assign sel_andi = q1_f100 && (q1_f100_type == 2'b10);
  assign sel_sub = q1_f100_is_alu && (q1_f100_alu_op == 2'b00);
  assign sel_xor = q1_f100_is_alu && (q1_f100_alu_op == 2'b01);
  assign sel_or = q1_f100_is_alu && (q1_f100_alu_op == 2'b10);
  assign sel_and = q1_f100_is_alu && (q1_f100_alu_op == 2'b11);
  assign sel_j = (quadrant == 2'b01) && (funct3 == 3'b101);
  assign sel_beqz = (quadrant == 2'b01) && (funct3 == 3'b110);
  assign sel_bnez = (quadrant == 2'b01) && (funct3 == 3'b111);

  // Quadrant 2 selects
  assign sel_slli = (quadrant == 2'b10) && (funct3 == 3'b000);
  assign sel_lwsp = (quadrant == 2'b10) && (funct3 == 3'b010);
  assign sel_jr = q2_f100 && !q2_f100_bit12 && (rs2_full == 5'd0);
  assign sel_mv = q2_f100 && !q2_f100_bit12 && (rs2_full != 5'd0);
  assign sel_ebreak = q2_f100 && q2_f100_bit12 && (rs2_full == 5'd0) && (rd_full == 5'd0);
  assign sel_jalr = q2_f100 && q2_f100_bit12 && (rs2_full == 5'd0) && (rd_full != 5'd0);
  assign sel_add = q2_f100 && q2_f100_bit12 && (rs2_full != 5'd0);
  assign sel_swsp = (quadrant == 2'b10) && (funct3 == 3'b110);

  // Quadrant 3 (not compressed - passthrough)
  assign sel_passthrough = (quadrant == 2'b11);

  // ===========================================================================
  // Illegal instruction detection (parallel)
  // ===========================================================================
  logic illegal_addi4spn;  // Zero immediate
  logic illegal_addi16sp;  // Zero immediate
  logic illegal_lui;  // Zero immediate or rd=0
  logic illegal_srli_srai;  // shamt[5]=1 for RV32
  logic illegal_slli;  // shamt[5]=1 or rd=0
  logic illegal_lwsp;  // rd=0
  logic illegal_jr;  // rs1=0
  logic illegal_mv_add;  // rd=0 (hint)
  logic illegal_q1_f100_reserved;  // RV64 only ops in RV32
  logic illegal_q0_reserved;  // Reserved Q0 encodings
  logic illegal_q1_reserved;  // Reserved Q1 encodings
  logic illegal_q2_reserved;  // Reserved Q2 encodings

  assign illegal_addi4spn = sel_addi4spn && (imm_addi4spn == 12'b0);
  assign illegal_addi16sp = sel_addi16sp && (imm_addi16sp == 12'b0);
  assign illegal_lui = (quadrant == 2'b01) && (funct3 == 3'b011) &&
                       ((rd_full == 5'd0) || ((rd_full != 5'd2) &&
                       ({i_instr_compressed[12], i_instr_compressed[6:2]} == 6'b0)));
  assign illegal_srli_srai = (sel_srli || sel_srai) && i_instr_compressed[12];
  assign illegal_slli = sel_slli && (i_instr_compressed[12] || (rd_full == 5'd0));
  assign illegal_lwsp = sel_lwsp && (rd_full == 5'd0);
  assign illegal_jr = sel_jr && (rd_full == 5'd0);
  assign illegal_mv_add = (sel_mv || sel_add) && (rd_full == 5'd0);
  assign illegal_q1_f100_reserved = q1_f100 && (q1_f100_type == 2'b11) && i_instr_compressed[12];

  // Reserved funct3 values in each quadrant
  assign illegal_q0_reserved = (quadrant == 2'b00) &&
                               (funct3 != 3'b000) && (funct3 != 3'b010) && (funct3 != 3'b110);
  assign illegal_q1_reserved = 1'b0;  // All funct3 used in Q1
  assign illegal_q2_reserved = (quadrant == 2'b10) &&
                               (funct3 != 3'b000) && (funct3 != 3'b010) &&
                               (funct3 != 3'b100) && (funct3 != 3'b110);

  assign o_illegal = illegal_addi4spn | illegal_addi16sp | illegal_lui |
                     illegal_srli_srai | illegal_slli | illegal_lwsp |
                     illegal_jr | illegal_mv_add | illegal_q1_f100_reserved |
                     illegal_q0_reserved | illegal_q2_reserved;

  // ===========================================================================
  // Hierarchical mux for instruction output (timing optimized)
  // ===========================================================================
  // Group by quadrant first, then select within quadrant.
  // This reduces mux depth: instead of 27-input OR (5 levels), we have:
  //   - ~8 inputs per quadrant (3 levels) computed in parallel
  //   - 4-input final mux (2 levels, but quadrant known early from bits[1:0])
  // Total effective depth reduced since quadrant decode is very fast.

  // Quadrant 0 result (3 instructions: addi4spn, lw, sw)
  logic [31:0] q0_result;
  assign q0_result = ({32{sel_addi4spn}} & instr_addi4spn) |
                     ({32{sel_lw}} & instr_lw) |
                     ({32{sel_sw}} & instr_sw);

  // Quadrant 1 result (15 instructions)
  logic [31:0] q1_result;
  assign q1_result = ({32{sel_addi}} & instr_addi) |
                     ({32{sel_jal}} & instr_jal) |
                     ({32{sel_li}} & instr_li) |
                     ({32{sel_addi16sp}} & instr_addi16sp) |
                     ({32{sel_lui}} & instr_lui) |
                     ({32{sel_srli}} & instr_srli) |
                     ({32{sel_srai}} & instr_srai) |
                     ({32{sel_andi}} & instr_andi) |
                     ({32{sel_sub}} & instr_sub) |
                     ({32{sel_xor}} & instr_xor) |
                     ({32{sel_or}} & instr_or) |
                     ({32{sel_and}} & instr_and) |
                     ({32{sel_j}} & instr_j) |
                     ({32{sel_beqz}} & instr_beqz) |
                     ({32{sel_bnez}} & instr_bnez);

  // Quadrant 2 result (8 instructions: slli, lwsp, jr, mv, ebreak, jalr, add, swsp)
  logic [31:0] q2_result;
  assign q2_result = ({32{sel_slli}} & instr_slli) |
                     ({32{sel_lwsp}} & instr_lwsp) |
                     ({32{sel_jr}} & instr_jr) |
                     ({32{sel_mv}} & instr_mv) |
                     ({32{sel_ebreak}} & instr_ebreak) |
                     ({32{sel_jalr}} & instr_jalr) |
                     ({32{sel_add}} & instr_add) |
                     ({32{sel_swsp}} & instr_swsp);

  // Final quadrant selection - quadrant bits are available immediately
  // Use simple 2-bit mux instead of one-hot for final stage
  always_comb begin
    unique case (quadrant)
      2'b00:   o_instr_expanded = q0_result;
      2'b01:   o_instr_expanded = q1_result;
      2'b10:   o_instr_expanded = q2_result;
      default: o_instr_expanded = {16'b0, i_instr_compressed};  // Q3: passthrough
    endcase
  end

endmodule : rvc_decompressor
