#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Operation tables mapping instruction mnemonics to encoders and evaluators.

Op Tables
=========

This module is the central registry that connects instruction mnemonics
(like "add", "lw", "beq") to their corresponding:

    1. Encoder function: Converts instruction parameters to 32-bit binary
    2. Evaluator function: Computes the result in software (for verification)

Architecture:
    The op tables enable a data-driven approach where adding a new instruction
    only requires updating this file - no changes to test logic needed.

Table Structure:
    Each table maps: mnemonic -> (encoder_function, evaluator_function)

    - R_ALU: Register-register operations (add, sub, mul, div, etc.)
    - I_ALU: Immediate ALU operations (addi, andi, slli, etc.)
    - LOADS: Load operations (lw, lh, lb, lhu, lbu)
    - STORES: Store operations (sw, sh, sb) - encoder only
    - BRANCHES: Conditional branches (beq, bne, blt, etc.) - encoder only
    - JUMPS: Jump operations (jal, jalr)

Example Usage:
    >>> # Look up ADD instruction
    >>> encoder, evaluator = R_ALU["add"]
    >>> # Encode: add x5, x3, x4
    >>> binary = encoder(rd=5, rs1=3, rs2=4)
    >>> # Evaluate: compute result
    >>> result = evaluator(register[3], register[4])

Adding New Instructions:
    1. Implement evaluator function in alu_model.py (if needed)
    2. Add entry to appropriate table here
    3. That's it! Test will automatically cover it.
"""

from collections.abc import Callable

from encoders.instruction_encode import (
    enc_r,
    enc_i,
    enc_i_load,
    enc_i_jalr,
    enc_s,
    enc_b,
    enc_j,
    enc_fence,
    enc_fence_i,
    enc_pause,
    enc_csrrw,
    enc_csrrs,
    enc_csrrc,
    enc_csrrwi,
    enc_csrrsi,
    enc_csrrci,
    CSRAddress,
    # A extension (atomics)
    enc_lr_w,
    enc_sc_w,
    enc_amoswap_w,
    enc_amoadd_w,
    enc_amoxor_w,
    enc_amoand_w,
    enc_amoor_w,
    enc_amomin_w,
    enc_amomax_w,
    enc_amominu_w,
    enc_amomaxu_w,
    # Machine-mode trap instructions
    enc_ecall,
    enc_ebreak,
    enc_mret,
    enc_wfi,
)
from encoders.compressed_encode import (
    # C extension (compressed instructions)
    enc_c_addi,
    enc_c_li,
    enc_c_lui,
    enc_c_addi16sp,
    enc_c_slli,
    enc_c_srli,
    enc_c_srai,
    enc_c_andi,
    enc_c_mv,
    enc_c_add,
    enc_c_sub,
    enc_c_xor,
    enc_c_or,
    enc_c_and,
    enc_c_lw,
    enc_c_sw,
    enc_c_lwsp,
    enc_c_swsp,
    enc_c_j,
    enc_c_jal,
    enc_c_jr,
    enc_c_jalr,
    enc_c_beqz,
    enc_c_bnez,
    is_compressible_reg,
)
from models.alu_model import (
    add,
    sub,
    and_rv,
    or_rv,
    xor,
    sll,
    srl,
    sra,
    slt,
    sltu,
    mul,
    mulh,
    mulhsu,
    mulhu,
    div,
    divu,
    rem,
    remu,
    lw,
    lb,
    lbu,
    lh,
    lhu,
    # Zba extension
    sh1add,
    sh2add,
    sh3add,
    # Zbs extension
    bset,
    bclr,
    binv,
    bext,
    # Zbb extension
    andn,
    orn,
    xnor,
    max_rv,
    maxu,
    min_rv,
    minu,
    rol,
    ror,
    clz,
    ctz,
    cpop,
    sext_b,
    sext_h,
    zext_h,
    orc_b,
    rev8,
    # Zicond extension
    czero_eqz,
    czero_nez,
    # Zbkb extension
    pack,
    packh,
    brev8,
    zip_rv,
    unzip,
    # A extension (atomics)
    amoswap,
    amoadd,
    amoxor,
    amoand,
    amoor,
    amomin,
    amomax,
    amominu,
    amomaxu,
)


def make_r_encoder(f7: int, f3: int) -> Callable:
    """Create R-type instruction encoders."""
    return lambda rd, rs1, rs2: enc_r(f7, rs2, rs1, f3, rd)


def make_i_encoder(f3: int) -> Callable:
    """Create I-type ALU instruction encoders."""
    return lambda rd, rs1, imm: enc_i(imm, rs1, f3, rd)


def make_i_shift_encoder(f3: int, f7: int) -> Callable:
    """Create I-type shift instruction encoders."""
    return lambda rd, rs1, sh: enc_i((sh & 0x1F) | (f7 << 5), rs1, f3, rd)


def make_i_unary_encoder(f3: int, f7: int, rs2_field: int) -> Callable:
    """Create I-type unary instruction encoders (Zbb clz, ctz, cpop, sext.b, sext.h).

    These instructions encode the operation type in both funct7 and rs2 field,
    and only take one source register operand.
    """
    return lambda rd, rs1: enc_i((rs2_field & 0x1F) | (f7 << 5), rs1, f3, rd)


def make_i_fixed_encoder(f3: int, f7: int, rs2_field: int) -> Callable:
    """Create I-type instruction encoders with fixed rs2 field (Zbb orc.b, rev8).

    These instructions use a fixed value in the rs2 field.
    """
    return lambda rd, rs1: enc_i((rs2_field & 0x1F) | (f7 << 5), rs1, f3, rd)


def make_r_unary_encoder(f7: int, f3: int) -> Callable:
    """Create R-type unary instruction encoder (zext.h uses this with rs2=0).

    These are R-type instructions that only use rs1 (rs2 is always 0).
    """
    return lambda rd, rs1: enc_r(f7, 0, rs1, f3, rd)


def make_load_encoder(f3: int) -> Callable:
    """Create load instruction encoders."""
    return lambda rd, rs1, imm: enc_i_load(imm, rs1, f3, rd)


def make_store_encoder(f3: int) -> Callable:
    """Create store instruction encoders."""
    return lambda rs2, rs1, imm: enc_s(rs2, rs1, f3, imm)


def make_branch_encoder(f3: int) -> Callable:
    """Create branch instruction encoders."""
    return lambda rs2, rs1, offset: enc_b(rs2, rs1, f3, offset)


# operation tables (opcode name → (encoder, evaluator))
# encoder encodes each instruction into raw bits to drive into the DUT
# evaluator is the function to actually evaluate the specific instruction and model the result
R_ALU: dict[str, tuple[Callable, Callable]] = {
    # base-ISA
    "add": (make_r_encoder(0x00, 0x0), add),
    "sub": (make_r_encoder(0x20, 0x0), sub),
    "and": (make_r_encoder(0x00, 0x7), and_rv),
    "or": (make_r_encoder(0x00, 0x6), or_rv),
    "xor": (make_r_encoder(0x00, 0x4), xor),
    "sll": (make_r_encoder(0x00, 0x1), sll),
    "srl": (make_r_encoder(0x00, 0x5), srl),
    "sra": (make_r_encoder(0x20, 0x5), sra),
    "slt": (make_r_encoder(0x00, 0x2), slt),
    "sltu": (make_r_encoder(0x00, 0x3), sltu),
    # M-extension
    "mul": (make_r_encoder(0x01, 0x0), mul),
    "mulh": (make_r_encoder(0x01, 0x1), mulh),
    "mulhsu": (make_r_encoder(0x01, 0x2), mulhsu),
    "mulhu": (make_r_encoder(0x01, 0x3), mulhu),
    "div": (make_r_encoder(0x01, 0x4), div),
    "divu": (make_r_encoder(0x01, 0x5), divu),
    "rem": (make_r_encoder(0x01, 0x6), rem),
    "remu": (make_r_encoder(0x01, 0x7), remu),
    # Zba extension - address generation
    "sh1add": (make_r_encoder(0x10, 0x2), sh1add),
    "sh2add": (make_r_encoder(0x10, 0x4), sh2add),
    "sh3add": (make_r_encoder(0x10, 0x6), sh3add),
    # Zbs extension - single-bit operations (register form)
    "bset": (make_r_encoder(0x14, 0x1), bset),
    "bclr": (make_r_encoder(0x24, 0x1), bclr),
    "binv": (make_r_encoder(0x34, 0x1), binv),
    "bext": (make_r_encoder(0x24, 0x5), bext),
    # Zbb extension - logical with complement
    "andn": (make_r_encoder(0x20, 0x7), andn),
    "orn": (make_r_encoder(0x20, 0x6), orn),
    "xnor": (make_r_encoder(0x20, 0x4), xnor),
    # Zbb extension - min/max comparisons
    "max": (make_r_encoder(0x05, 0x6), max_rv),
    "maxu": (make_r_encoder(0x05, 0x7), maxu),
    "min": (make_r_encoder(0x05, 0x4), min_rv),
    "minu": (make_r_encoder(0x05, 0x5), minu),
    # Zbb extension - rotations (register form)
    "rol": (make_r_encoder(0x30, 0x1), rol),
    "ror": (make_r_encoder(0x30, 0x5), ror),
    # Zicond extension - conditional operations
    "czero.eqz": (make_r_encoder(0x07, 0x5), czero_eqz),
    "czero.nez": (make_r_encoder(0x07, 0x7), czero_nez),
    # Zbkb extension - bit manipulation for crypto
    "pack": (make_r_encoder(0x04, 0x4), pack),
    "packh": (make_r_encoder(0x04, 0x7), packh),
}

I_ALU: dict[str, tuple[Callable, Callable]] = {
    "addi": (make_i_encoder(0x0), add),
    "andi": (make_i_encoder(0x7), and_rv),
    "ori": (make_i_encoder(0x6), or_rv),
    "xori": (make_i_encoder(0x4), xor),
    "slli": (make_i_shift_encoder(0x1, 0x00), sll),
    "srli": (make_i_shift_encoder(0x5, 0x00), srl),
    "srai": (make_i_shift_encoder(0x5, 0x20), sra),
    "slti": (make_i_encoder(0x2), slt),
    "sltiu": (make_i_encoder(0x3), sltu),
    # Zbs extension - single-bit operations (immediate form)
    "bseti": (make_i_shift_encoder(0x1, 0x14), bset),
    "bclri": (make_i_shift_encoder(0x1, 0x24), bclr),
    "binvi": (make_i_shift_encoder(0x1, 0x34), binv),
    "bexti": (make_i_shift_encoder(0x5, 0x24), bext),
    # Zbb extension - rotate immediate
    "rori": (make_i_shift_encoder(0x5, 0x30), ror),
}

LOADS: dict[str, tuple[Callable, Callable]] = {
    "lw": (make_load_encoder(0x2), lw),
    "lb": (make_load_encoder(0x0), lb),
    "lbu": (make_load_encoder(0x4), lbu),
    "lh": (make_load_encoder(0x1), lh),
    "lhu": (make_load_encoder(0x5), lhu),
}

STORES: dict[str, Callable] = {
    "sw": make_store_encoder(0x2),
    "sb": make_store_encoder(0x0),
    "sh": make_store_encoder(0x1),
}

BRANCHES: dict[str, Callable] = {
    "beq": make_branch_encoder(0x0),
    "bne": make_branch_encoder(0x1),
    "blt": make_branch_encoder(0x4),
    "bge": make_branch_encoder(0x5),
    "bltu": make_branch_encoder(0x6),
    "bgeu": make_branch_encoder(0x7),
}

JUMPS: dict[str, Callable] = {
    "jal": lambda rd, offset: enc_j(rd, offset),
    "jalr": lambda rd, rs1, imm: enc_i_jalr(imm, rs1, rd),
}

# Zifencei extension - memory ordering instructions
# These are effectively NOPs in this implementation (no I-cache, in-order execution)
# Encoder only, no evaluator needed (they don't produce a result)
FENCES: dict[str, Callable] = {
    "fence": enc_fence,
    "fence.i": enc_fence_i,
    # Zihintpause extension
    "pause": enc_pause,
}

# Zicsr extension - CSR read/modify/write instructions
# These instructions read the old CSR value into rd
# The encoder takes: (rd, csr_address, rs1_or_zimm)
# Note: For Zicntr read-only counters, we only use CSRRS with rs1=x0 (pseudo: CSRR rd, csr)
CSRS: dict[str, Callable] = {
    "csrrw": enc_csrrw,
    "csrrs": enc_csrrs,
    "csrrc": enc_csrrc,
    "csrrwi": enc_csrrwi,
    "csrrsi": enc_csrrsi,
    "csrrci": enc_csrrci,
}

# Zicntr CSR addresses for random testing
# Note: CYCLE and TIME are excluded because they increment every clock cycle,
# making their values hard to predict when stalls (from mul/div) occur.
# The high-32-bit counters (CYCLEH, TIMEH, INSTRETH) are included since they're
# always 0 for short tests. INSTRET is included since it only increments when
# instructions retire (more predictable timing than CYCLE).
ZICNTR_CSRS: list[int] = [
    CSRAddress.INSTRET,
    CSRAddress.CYCLEH,
    CSRAddress.TIMEH,
    CSRAddress.INSTRETH,
]

# Zbb extension - unary bit manipulation operations
# These instructions take only one source register operand (rd, rs1)
# The operation type is encoded in funct7 + rs2 field
I_UNARY: dict[str, tuple[Callable, Callable]] = {
    # funct3=1, funct7=0x30, rs2 encodes operation
    "clz": (make_i_unary_encoder(0x1, 0x30, 0), clz),
    "ctz": (make_i_unary_encoder(0x1, 0x30, 1), ctz),
    "cpop": (make_i_unary_encoder(0x1, 0x30, 2), cpop),
    "sext.b": (make_i_unary_encoder(0x1, 0x30, 4), sext_b),
    "sext.h": (make_i_unary_encoder(0x1, 0x30, 5), sext_h),
    # zext.h is R-type (opcode 0x33) with funct7=0x04, funct3=4, rs2=0
    "zext.h": (make_r_unary_encoder(0x04, 0x4), zext_h),
    # funct3=5, fixed rs2 value
    "orc.b": (make_i_fixed_encoder(0x5, 0x14, 7), orc_b),
    "rev8": (make_i_fixed_encoder(0x5, 0x34, 0x18), rev8),
    # Zbkb extension - bit manipulation for crypto
    "brev8": (make_i_fixed_encoder(0x5, 0x34, 7), brev8),
    "zip": (make_i_fixed_encoder(0x1, 0x04, 15), zip_rv),
    "unzip": (make_i_fixed_encoder(0x5, 0x04, 15), unzip),
}

# A extension (atomics) - Atomic Memory Operations
# AMO instructions atomically load a value, perform an operation, and store the result.
# rd receives the original memory value; the new value is written to memory.
#
# LR.W/SC.W (Load-Reserved/Store-Conditional):
#   - LR.W: Loads word and sets reservation (encoder only, evaluator is lw)
#   - SC.W: Stores if reservation valid (encoder only, special handling in test)
#
# AMO operations (encoder, evaluator):
#   - Encoder: lambda rd, rs2, rs1 -> 32-bit instruction
#   - Evaluator: lambda old_value, rs2_value -> new_value for memory
AMO_LR_SC: dict[str, Callable] = {
    "lr.w": enc_lr_w,
    "sc.w": enc_sc_w,
}

AMO: dict[str, tuple[Callable, Callable]] = {
    "amoswap.w": (enc_amoswap_w, amoswap),
    "amoadd.w": (enc_amoadd_w, amoadd),
    "amoxor.w": (enc_amoxor_w, amoxor),
    "amoand.w": (enc_amoand_w, amoand),
    "amoor.w": (enc_amoor_w, amoor),
    "amomin.w": (enc_amomin_w, amomin),
    "amomax.w": (enc_amomax_w, amomax),
    "amominu.w": (enc_amominu_w, amominu),
    "amomaxu.w": (enc_amomaxu_w, amomaxu),
}

# Machine-mode trap instructions (encoder only, no evaluator)
# These are NOT included in random tests because they cause control flow changes
# that require specific trap handler setup. Use directed tests instead.
#
# ECALL: Environment call - triggers exception, jumps to mtvec
# EBREAK: Breakpoint exception - triggers exception, jumps to mtvec
# MRET: Return from trap - restores PC from mepc, restores mstatus
# WFI: Wait for interrupt - stalls until interrupt pending
TRAP_INSTRS: dict[str, Callable] = {
    "ecall": enc_ecall,
    "ebreak": enc_ebreak,
    "mret": enc_mret,
    "wfi": enc_wfi,
}

# =============================================================================
# C extension (compressed instructions)
# =============================================================================
#
# Compressed instructions are 16-bit encodings that decompress to 32-bit
# equivalents in the IF stage. The evaluators are the same as the base ISA
# since they produce identical results after decompression.
#
# Note: Compressed instructions have constraints on which registers can be used:
# - Many instructions only work with x8-x15 (compressed register encoding)
# - Some instructions have limited immediate ranges
#
# The encoder functions return 16-bit values. The test framework is responsible
# for packing these into 32-bit words based on PC alignment.

# C extension ALU operations (register-register, using x8-x15)
# Format: (encoder, evaluator)
# encoder: lambda rd', rs2' -> 16-bit instruction (rd' and rs2' must be 8-15)
C_ALU_REG: dict[str, tuple[Callable, Callable]] = {
    "c.sub": (lambda rd, rs2: enc_c_sub(rd, rs2), sub),
    "c.xor": (lambda rd, rs2: enc_c_xor(rd, rs2), xor),
    "c.or": (lambda rd, rs2: enc_c_or(rd, rs2), or_rv),
    "c.and": (lambda rd, rs2: enc_c_and(rd, rs2), and_rv),
}

# C extension ALU operations (full register set)
# Format: (encoder, evaluator)
C_ALU_FULL: dict[str, tuple[Callable, Callable]] = {
    "c.mv": (lambda rd, rs2: enc_c_mv(rd, rs2), add),  # add rd, x0, rs2
    "c.add": (lambda rd, rs2: enc_c_add(rd, rs2), add),  # add rd, rd, rs2
}

# C extension immediate ALU operations (limited register set x8-x15)
# Format: (encoder, evaluator)
C_ALU_IMM_LIMITED: dict[str, tuple[Callable, Callable]] = {
    "c.srli": (lambda rd, shamt: enc_c_srli(rd, shamt), srl),
    "c.srai": (lambda rd, shamt: enc_c_srai(rd, shamt), sra),
    "c.andi": (lambda rd, imm: enc_c_andi(rd, imm), and_rv),
}

# C extension immediate ALU operations (full register set)
# Format: (encoder, evaluator)
C_ALU_IMM_FULL: dict[str, tuple[Callable, Callable]] = {
    "c.addi": (lambda rd, imm: enc_c_addi(rd, imm), add),
    "c.li": (lambda rd, imm: enc_c_li(rd, imm), add),  # addi rd, x0, imm
    "c.slli": (lambda rd, shamt: enc_c_slli(rd, shamt), sll),
}

# C extension load/store operations (limited register set x8-x15)
# Format: (encoder, evaluator)
C_LOADS_LIMITED: dict[str, tuple[Callable, Callable]] = {
    "c.lw": (lambda rd, rs1, uimm: enc_c_lw(rd, rs1, uimm), lw),
}

C_STORES_LIMITED: dict[str, Callable] = {
    "c.sw": lambda rs1, rs2, uimm: enc_c_sw(rs1, rs2, uimm),
}

# C extension stack-relative load/store operations (full register set)
C_LOADS_STACK: dict[str, tuple[Callable, Callable]] = {
    "c.lwsp": (lambda rd, uimm: enc_c_lwsp(rd, uimm), lw),
}

C_STORES_STACK: dict[str, Callable] = {
    "c.swsp": lambda rs2, uimm: enc_c_swsp(rs2, uimm),
}

# C extension branch operations (limited register set x8-x15)
# Format: encoder (evaluator not needed - branch taken/not taken is checked separately)
C_BRANCHES: dict[str, Callable] = {
    "c.beqz": lambda rs1, offset: enc_c_beqz(rs1, offset),
    "c.bnez": lambda rs1, offset: enc_c_bnez(rs1, offset),
}

# C extension jump operations
C_JUMPS: dict[str, Callable] = {
    "c.j": lambda offset: enc_c_j(offset),
    "c.jal": lambda offset: enc_c_jal(offset),
    "c.jr": lambda rs1: enc_c_jr(rs1),
    "c.jalr": lambda rs1: enc_c_jalr(rs1),
}

# C extension special operations
C_SPECIAL: dict[str, tuple[Callable, Callable]] = {
    "c.lui": (lambda rd, imm: enc_c_lui(rd, imm), lambda x, y: (y << 12) & 0xFFFFFFFF),
    "c.addi16sp": (lambda imm: enc_c_addi16sp(imm), add),
}

# Helper to check if a register can be used in compressed instructions
is_compressed_reg = is_compressible_reg
