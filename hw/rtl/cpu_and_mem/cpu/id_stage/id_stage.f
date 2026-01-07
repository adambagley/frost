# Instruction Decode (ID) stage file list
# Decodes RISC-V instructions and extracts immediate values

# Instruction decoder - determines operation type from opcode/funct fields
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv

# ID stage integration - extracts immediates and pipelines to EX stage
$(ROOT)/hw/rtl/cpu_and_mem/cpu/id_stage/id_stage.sv
