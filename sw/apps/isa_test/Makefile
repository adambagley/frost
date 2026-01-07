# Makefile for ISA Compliance Test Suite
# Comprehensive tests for all RISC-V extensions supported by Frost

# Use O2 to avoid GP-relative relocation overflow (large test suite)
OPT_LEVEL := -O2
# Disable loop unrolling (causes compilation failure)
UNROLL_LOOPS :=

SRC_C   := ../../lib/src/uart.c ../../lib/src/string.c isa_test.c
include ../../common/common.mk
