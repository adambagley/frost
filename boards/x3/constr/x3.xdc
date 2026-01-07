# Xilinx Design Constraints (XDC) for X3 board
# Pin assignments, I/O standards, and timing constraints for UltraScale+ FPGA

# ================================================================
# BITSTREAM GENERATION CONFIGURATION
# ================================================================
# I/O voltage
set_property CONFIG_VOLTAGE 1.8                        [current_design]
# Fallback to previous bitstream on error
set_property BITSTREAM.CONFIG.CONFIGFALLBACK Enable    [current_design]
# Compress bitstream for faster loading
set_property BITSTREAM.GENERAL.COMPRESS TRUE           [current_design]
# Quad SPI configuration mode
set_property CONFIG_MODE SPIx4                         [current_design]
# 4-bit SPI bus
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4           [current_design]
# Use internal clock for configuration
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN disable [current_design]
# Configuration clock rate (MHz)
set_property BITSTREAM.CONFIG.CONFIGRATE 85.0          [current_design]
# Use falling edge for SPI
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES        [current_design]
# Pull up unused pins
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup         [current_design]
# Use 32-bit SPI addressing
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR Yes       [current_design]

# ================================================================
# CLOCK - 300MHz differential system clock
# ================================================================
# Negative clock input
set_property -dict {PACKAGE_PIN AL23 IOSTANDARD LVDS} [get_ports i_sysclk_n]
# Positive clock input
set_property -dict {PACKAGE_PIN AK23 IOSTANDARD LVDS} [get_ports i_sysclk_p]
# 300MHz = 3.333ns period
create_clock -period 3.333 -name sysclk [get_ports i_sysclk_p]

# ================================================================
# UART - Serial communication for debug console
# ================================================================
# UART transmit
set_property -dict {PACKAGE_PIN AP24 IOSTANDARD LVCMOS18} [get_ports o_uart_tx]
# UART receive
set_property -dict {PACKAGE_PIN AR24 IOSTANDARD LVCMOS18} [get_ports i_uart_rx]
