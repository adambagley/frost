# FROST RISC-V processor top-level file list
# Contains all RTL source files for synthesis and simulation
# $(ROOT) is expanded to repository root by build scripts

# FIFO library (used for clock domain crossing)
# Note: RAM library is included by cpu_and_mem.f
-f $(ROOT)/hw/rtl/lib/fifo/fifo.f

# CPU and memory subsystem (includes all pipeline stages and RAM library)
-f $(ROOT)/hw/rtl/cpu_and_mem/cpu_and_mem.f

# Peripheral modules (UART, etc.)
-f $(ROOT)/hw/rtl/peripherals/peripherals.f

# Top-level FROST integration module
$(ROOT)/hw/rtl/frost.sv
