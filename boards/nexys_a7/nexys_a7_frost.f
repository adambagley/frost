# Nexys A7 board top-level file list
# Includes FROST core plus Nexys A7-specific clock generation and JTAG interface

# FROST RISC-V processor core and all submodules
-f $(ROOT)/hw/rtl/frost.f

# Common Xilinx FROST subsystem (JTAG, BRAM controller, CPU)
$(ROOT)/boards/xilinx_frost_subsystem.sv

# Nexys A7 board wrapper with Artix-7 FPGA primitives
$(ROOT)/boards/nexys_a7/nexys_a7_frost.sv
