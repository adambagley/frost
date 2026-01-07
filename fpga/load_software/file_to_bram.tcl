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

# ---------------------------------------------------------------
# file2bram.tcl - Load firmware file into FPGA BRAM via AXI4-Lite
# ---------------------------------------------------------------
# Reads hex file (one 32-bit word per line) and writes to BRAM through
# JTAG-to-AXI bridge. Used for loading software without reprogramming FPGA.

proc file2bram {base_memory_address firmware_filename {axi_interface_name hw_axi_1}} {

    # Open firmware file (text format: 8 hex digits per line)
    set file_descriptor [open $firmware_filename r]
    set current_address $base_memory_address
    set transaction_number 0

    # Read file line by line - each line is one 32-bit word in hexadecimal
    while {[gets $file_descriptor word_hex_value] >= 0} {
        set formatted_address [format 0x%08x $current_address]
        # Create AXI write transaction for this word
        create_hw_axi_txn wr$transaction_number [get_hw_axis $axi_interface_name] \
            -type write -address $formatted_address -len 1 -data $word_hex_value
        incr transaction_number
        # Move to next word (4 bytes)
        incr current_address 4
    }
    close $file_descriptor

    # Execute all queued AXI transactions
    run_hw_axi [get_hw_axi_txns]

    puts "Loaded $transaction_number words starting at [format 0x%08x $base_memory_address]"
}
