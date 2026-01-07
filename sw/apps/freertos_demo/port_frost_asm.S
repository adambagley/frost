/*
 * FROST-specific FreeRTOS port assembly
 *
 * Provides trap handler and context switching for FROST RISC-V M-mode.
 */

.section .text
.align 2

.global freertos_risc_v_trap_handler
.global pxCurrentTCB
.global xPortStartFirstTask

/* FreeRTOS external functions */
.extern vPortTimerTickHandler
.extern freertos_risc_v_application_exception_handler
.extern freertos_risc_v_application_interrupt_handler
.extern vPortDebugTrap
.extern vPortDebugRestore
.extern vPortDebugTCB
.extern vPortDebugRA

/* Critical section nesting counter */
.extern uxCriticalNesting

/* Context size: 28 GPRs + mepc + mstatus + uxCriticalNesting = 31 words = 124 bytes, round to 128 */
#define portCONTEXT_SIZE 128

/*-----------------------------------------------------------*/
/* freertos_risc_v_trap_handler
 *
 * Main trap entry point - handles both exceptions and interrupts.
 */
.align 4
freertos_risc_v_trap_handler:
    /* Save context on current stack */
    addi sp, sp, -portCONTEXT_SIZE

    /* Save all registers */
    sw x1,  0*4(sp)
    sw x5,  1*4(sp)
    sw x6,  2*4(sp)
    sw x7,  3*4(sp)
    sw x8,  4*4(sp)
    sw x9,  5*4(sp)
    sw x10, 6*4(sp)
    sw x11, 7*4(sp)
    sw x12, 8*4(sp)
    sw x13, 9*4(sp)
    sw x14, 10*4(sp)
    sw x15, 11*4(sp)
    sw x16, 12*4(sp)
    sw x17, 13*4(sp)
    sw x18, 14*4(sp)
    sw x19, 15*4(sp)
    sw x20, 16*4(sp)
    sw x21, 17*4(sp)
    sw x22, 18*4(sp)
    sw x23, 19*4(sp)
    sw x24, 20*4(sp)
    sw x25, 21*4(sp)
    sw x26, 22*4(sp)
    sw x27, 23*4(sp)
    sw x28, 24*4(sp)
    sw x29, 25*4(sp)
    sw x30, 26*4(sp)
    sw x31, 27*4(sp)

    /* Save mepc */
    csrr t0, mepc
    sw t0, 28*4(sp)

    /* Save mstatus */
    csrr t1, mstatus
    sw t1, 29*4(sp)

    /* Save uxCriticalNesting to stack */
    la t0, uxCriticalNesting
    lw t1, 0(t0)
    sw t1, 30*4(sp)

    /* Save current SP to pxCurrentTCB if it exists */
    la t0, pxCurrentTCB
    lw t1, 0(t0)
    beqz t1, skip_save_sp
    sw sp, 0(t1)

skip_save_sp:
    /* Set uxCriticalNesting to 1 for trap handler execution */
    la t0, uxCriticalNesting
    li t1, 1
    sw t1, 0(t0)

    /* Check if interrupt or exception */
    csrr t0, mcause
    blt t0, zero, handle_interrupt

handle_exception:
    /* Check if it's an ECALL (yield request) - mcause = 11 */
    li t1, 11
    beq t0, t1, handle_yield

    /* Other exception - call application handler */
    call freertos_risc_v_application_exception_handler
    j trap_exit

handle_yield:
    /* ECALL: advance mepc past the ecall instruction (4 bytes) */
    lw t0, 28*4(sp)
    addi t0, t0, 4
    sw t0, 28*4(sp)

    /* Save current SP and TCB before calling vTaskSwitchContext
     * s0 = original SP (our context is here)
     * s1 = original pxCurrentTCB pointer */
    mv s0, sp
    la t0, pxCurrentTCB
    lw s1, 0(t0)

    /* Call vTaskSwitchContext to select next task */
    call vTaskSwitchContext

    /* Check if pxCurrentTCB changed */
    la t0, pxCurrentTCB
    lw t1, 0(t0)
    beq t1, s1, yield_same_task  /* Same task - use our saved SP */

    /* Different task - reload SP from new pxCurrentTCB */
    beqz t1, yield_same_task
    lw sp, 0(t1)
    j trap_exit

yield_same_task:
    /* Same task - restore our original SP */
    mv sp, s0
    j trap_exit

handle_interrupt:
    /* Check if it's timer interrupt (mcause = 0x80000007) */
    li t1, 0x80000007
    beq t0, t1, handle_timer

    /* Other interrupt - call application handler */
    call freertos_risc_v_application_interrupt_handler
    j trap_exit

handle_timer:
    /* Save current SP and TCB before calling handler
     * s0 = original SP (our context is here)
     * s1 = original pxCurrentTCB pointer */
    mv s0, sp
    la t0, pxCurrentTCB
    lw s1, 0(t0)

    /* Call C timer handler (may call vTaskSwitchContext) */
    call vPortTimerTickHandler

    /* Check SAVED uxCriticalNesting on stack
     * If it was > 0, don't switch at all */
    lw t1, 30*4(sp)
    bnez t1, timer_same_task

    /* Check if pxCurrentTCB changed */
    la t0, pxCurrentTCB
    lw t1, 0(t0)
    beq t1, s1, timer_same_task  /* Same task - use our saved SP */

    /* Different task - reload SP from new pxCurrentTCB */
    beqz t1, timer_same_task
    lw sp, 0(t1)
    j trap_exit

timer_same_task:
    /* Same task - restore our original SP */
    mv sp, s0
    /* Fall through to trap_exit */

trap_exit:
    /* Restore uxCriticalNesting from stack */
    lw t1, 30*4(sp)
    la t0, uxCriticalNesting
    sw t1, 0(t0)

    /* Restore mstatus */
    lw t1, 29*4(sp)
    csrw mstatus, t1

    /* Restore mepc */
    lw t0, 28*4(sp)
    csrw mepc, t0

    /* Restore all registers */
    lw x31, 27*4(sp)
    lw x30, 26*4(sp)
    lw x29, 25*4(sp)
    lw x28, 24*4(sp)
    lw x27, 23*4(sp)
    lw x26, 22*4(sp)
    lw x25, 21*4(sp)
    lw x24, 20*4(sp)
    lw x23, 19*4(sp)
    lw x22, 18*4(sp)
    lw x21, 17*4(sp)
    lw x20, 16*4(sp)
    lw x19, 15*4(sp)
    lw x18, 14*4(sp)
    lw x17, 13*4(sp)
    lw x16, 12*4(sp)
    lw x15, 11*4(sp)
    lw x14, 10*4(sp)
    lw x13, 9*4(sp)
    lw x12, 8*4(sp)
    lw x11, 7*4(sp)
    lw x10, 6*4(sp)
    lw x9,  5*4(sp)
    lw x8,  4*4(sp)
    lw x7,  3*4(sp)
    lw x6,  2*4(sp)
    lw x5,  1*4(sp)
    lw x1,  0*4(sp)

    addi sp, sp, portCONTEXT_SIZE

    mret

/*-----------------------------------------------------------*/
/* xPortStartFirstTask
 *
 * Called from xPortStartScheduler to start the first task.
 */
xPortStartFirstTask:
    /* Load stack pointer from pxCurrentTCB */
    la t0, pxCurrentTCB
    lw t1, 0(t0)
    lw sp, 0(t1)

    /* Restore uxCriticalNesting from stack */
    lw t1, 30*4(sp)
    la t0, uxCriticalNesting
    sw t1, 0(t0)

    /* Restore mstatus */
    lw t1, 29*4(sp)
    csrw mstatus, t1

    /* Restore mepc */
    lw t0, 28*4(sp)
    csrw mepc, t0

    /* Restore all registers */
    lw x31, 27*4(sp)
    lw x30, 26*4(sp)
    lw x29, 25*4(sp)
    lw x28, 24*4(sp)
    lw x27, 23*4(sp)
    lw x26, 22*4(sp)
    lw x25, 21*4(sp)
    lw x24, 20*4(sp)
    lw x23, 19*4(sp)
    lw x22, 18*4(sp)
    lw x21, 17*4(sp)
    lw x20, 16*4(sp)
    lw x19, 15*4(sp)
    lw x18, 14*4(sp)
    lw x17, 13*4(sp)
    lw x16, 12*4(sp)
    lw x15, 11*4(sp)
    lw x14, 10*4(sp)
    lw x13, 9*4(sp)
    lw x12, 8*4(sp)
    lw x11, 7*4(sp)
    lw x10, 6*4(sp)
    lw x9,  5*4(sp)
    lw x8,  4*4(sp)
    lw x7,  3*4(sp)
    lw x6,  2*4(sp)
    lw x5,  1*4(sp)
    lw x1,  0*4(sp)

    addi sp, sp, portCONTEXT_SIZE

    mret
