# C Extension (Compressed Instructions) Test
#
# Tests function calls and returns using both 32-bit and 16-bit compressed
# instructions to verify correct PC handling and instruction decompression.
#
# Tests:
#   1. 32-bit JAL to function
#   2. C.JAL (16-bit compressed call)
#   3. Nested function calls with mixed instruction sizes
#   4. Multiple C.JAL in sequence
#   5. C.JALR (compressed indirect call)

    .section .init
    .option push
    .option norelax
    .globl _start

_start:
    .option norvc           # Force 32-bit for setup

    # Initialize stack pointer
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    # Load UART address into s0 (callee-saved, persists across calls)
    lui     s0, 0x40000

    # Print header
    la      a0, msg_header
    jal     ra, print_string

    # =========================================
    # Test 1: Basic 32-bit JAL
    # =========================================
    la      a0, msg_test1
    jal     ra, print_string
    jal     ra, simple_func     # 32-bit JAL
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 2: C.JAL (16-bit compressed call)
    # =========================================
    la      a0, msg_test2
    jal     ra, print_string
    .option rvc
    c.jal   simple_func         # Compressed JAL
    .option norvc
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 3: Nested calls with mixed sizes
    # =========================================
    la      a0, msg_test3
    jal     ra, print_string
    jal     ra, nested_func     # Calls simple_func internally
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 4: Multiple C.JAL in sequence
    # =========================================
    la      a0, msg_test4
    jal     ra, print_string
    .option rvc
    c.jal   simple_func
    c.jal   simple_func
    c.jal   simple_func
    .option norvc
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 5: C.JALR (compressed indirect)
    # =========================================
    la      a0, msg_test5
    jal     ra, print_string
    la      a1, simple_func     # Load function address
    .option rvc
    c.jalr  a1                  # Compressed indirect call
    .option norvc
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # All tests passed
    # =========================================
    la      a0, msg_pass
    jal     ra, print_string
    la      a0, msg_marker
    jal     ra, print_string

    .option rvc
done:
    c.j     done

# =========================================
# Helper: Print null-terminated string
# Input: a0 = pointer to string
# =========================================
    .option norvc
    .balign 4
print_string:
    mv      t2, a0              # Save string pointer
1:
    lb      t1, 0(t2)           # Load character
    beqz    t1, 2f              # Exit if null
    sb      t1, 0(s0)           # Write to UART
    addi    t2, t2, 1           # Next character
    j       1b
2:
    .option rvc
    c.jr    ra
    .option norvc

# =========================================
# Simple function (just returns)
# =========================================
    .balign 4
simple_func:
    .option rvc
    c.jr    ra
    .option norvc

# =========================================
# Nested function (calls simple_func twice)
# =========================================
    .balign 4
nested_func:
    addi    sp, sp, -16
    sw      ra, 12(sp)

    # Call with 32-bit JAL
    jal     ra, simple_func

    # Call with C.JAL
    .option rvc
    c.jal   simple_func
    .option norvc

    lw      ra, 12(sp)
    addi    sp, sp, 16
    .option rvc
    c.jr    ra
    .option norvc

    .option pop

# =========================================
# String data
# =========================================
    .section .rodata
msg_header:
    .asciz "=== C Extension Test ===\n"
msg_test1:
    .asciz "Test 1: 32-bit JAL... "
msg_test2:
    .asciz "Test 2: C.JAL... "
msg_test3:
    .asciz "Test 3: Nested calls... "
msg_test4:
    .asciz "Test 4: Multiple C.JAL... "
msg_test5:
    .asciz "Test 5: C.JALR... "
msg_ok:
    .asciz "OK\n"
msg_pass:
    .asciz "\n=== All Tests Passed ===\n"
msg_marker:
    .asciz "<<PASS>>\n"

# =========================================
# Stack
# =========================================
    .section .bss
    .align 4
stack_bottom:
    .space 512
_stack_top:
