# Register file (Writeback stage) file list
# Integer and FP register files for RISC-V pipeline
# Dependencies: sdp_dist_ram (from lib/ram)

# Integer register file - 2 read ports (rs1/rs2), 1 write port (rd)
$(ROOT)/hw/rtl/cpu_and_mem/cpu/wb_stage/regfile.sv

# F extension: FP register file - 3 read ports (fs1/fs2/fs3 for FMA), 1 write port
$(ROOT)/hw/rtl/cpu_and_mem/cpu/wb_stage/fp_regfile.sv
