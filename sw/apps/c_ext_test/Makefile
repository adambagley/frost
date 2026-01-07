# Makefile for C Extension Test
# Self-contained assembly test for compressed instruction handling
# Note: Uses custom build flow (not common.mk) because c_ext_test.S
# defines its own _start and doesn't use crt0.S

# Architecture - MUST match common.mk RISCV_FLAGS -march value
# If common.mk changes, update this value to match
ARCH = rv32imac_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause
ABI = ilp32

# Tools - use same prefix as common.mk
RISCV_PREFIX ?= riscv-none-elf-
AS      = $(RISCV_PREFIX)as
LD      = $(RISCV_PREFIX)ld
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

# Linker script
LINKER_SCRIPT = ../../common/link.ld

# Output files - same naming as common.mk
EXECUTABLE_ELF_FILE = sw.elf
VERILOG_HEX_FILE    = sw.mem
RAW_BINARY_FILE     = sw.bin
DISASSEMBLY_FILE    = sw.S

# Build targets
all: $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(DISASSEMBLY_FILE)

# Assemble and link in one step (no intermediate .o file)
$(EXECUTABLE_ELF_FILE): c_ext_test.S $(LINKER_SCRIPT)
	$(AS) -march=$(ARCH) -mabi=$(ABI) -o c_ext_test.o $<
	$(LD) -m elf32lriscv -T $(LINKER_SCRIPT) -o $@ c_ext_test.o
	@rm -f c_ext_test.o

# Generate Verilog HEX file - same format as common.mk
$(VERILOG_HEX_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O verilog --verilog-data-width 4 -R .comment -R .note.gnu.build-id $< $@

# Generate raw binary
$(RAW_BINARY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJCOPY) -O binary -R .comment -R .note.gnu.build-id $< $@

# Generate disassembly
$(DISASSEMBLY_FILE): $(EXECUTABLE_ELF_FILE)
	$(OBJDUMP) -d $< > $@

clean:
	rm -f $(EXECUTABLE_ELF_FILE) $(VERILOG_HEX_FILE) $(RAW_BINARY_FILE) $(DISASSEMBLY_FILE) c_ext_test.o

.PHONY: all clean
