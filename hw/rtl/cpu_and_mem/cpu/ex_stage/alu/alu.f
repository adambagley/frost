# ALU (Arithmetic Logic Unit) file list
# RV32IMAB ALU with base integer, M, A, and B extensions
# Note: B = Zba + Zbb + Zbs (full bit manipulation extension)

# 2-stage pipelined multiplier (uses FPGA DSP blocks)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/multiplier.sv

# 32-stage radix-2 restoring divider (fully pipelined)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/divider.sv

# ALU top-level - integrates all arithmetic and logical operations
$(ROOT)/hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv
