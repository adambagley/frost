# Genesys2 board top-level file list
# Includes FROST core plus Genesys2-specific clock generation and JTAG interface

# FROST RISC-V processor core and all submodules
-f $(ROOT)/hw/rtl/frost.f

# Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
$(ROOT)/boards/xilinx_frost_subsystem.sv

# Genesys2 board wrapper with Kintex-7 FPGA primitives
$(ROOT)/boards/genesys2/genesys2_frost.sv
