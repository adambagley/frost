# Register file (Writeback stage) file list
# Tri-port register file for simultaneous rs1/rs2 reads and rd write
# Dependencies: sdp_dist_ram (from lib/ram)

# Register file module - uses 2 RAM instances for 3-port access
$(ROOT)/hw/rtl/cpu_and_mem/cpu/wb_stage/regfile.sv
