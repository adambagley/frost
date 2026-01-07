/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * FreeRTOS Demo for FROST RISC-V Processor
 *
 * Demonstrates:
 *   - Multiple concurrent tasks
 *   - Inter-task communication via queues
 *   - Mutex for shared resource protection
 *   - Preemptive scheduling with priorities
 *   - Blocking/yielding behavior
 */

#include "FreeRTOS.h"
#include "queue.h"
#include "semphr.h"
#include "task.h"
#include "uart.h"

#define TASK_STACK_SIZE (512)
#define QUEUE_LENGTH (3)
#define NUM_ITEMS (5)

extern void freertos_risc_v_trap_handler(void);

/* Shared resources */
static QueueHandle_t xDataQueue = NULL;
static SemaphoreHandle_t xUartMutex = NULL;

/* Counters for demonstration */
static volatile uint32_t ulProducerCount = 0;
static volatile uint32_t ulConsumerCount = 0;

/*-----------------------------------------------------------*/
/* Safe UART output with mutex protection */

static void safe_print(const char *msg)
{
    if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
        uart_puts(msg);
        xSemaphoreGive(xUartMutex);
    }
}

/*-----------------------------------------------------------*/
/* Producer Task - generates data and sends to queue */

static void vProducerTask(void *pvParameters)
{
    (void) pvParameters;
    uint32_t ulValue;

    safe_print("[Producer] Task started\r\n");

    for (ulValue = 1; ulValue <= NUM_ITEMS; ulValue++) {
        /* Show we're about to send */
        if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
            uart_puts("[Producer] Sending item ");
            uart_putchar('0' + ulValue);
            uart_puts(" to queue...\r\n");
            xSemaphoreGive(xUartMutex);
        }

        /* Send to queue - may block if full */
        /* Increment count before send since consumer may preempt immediately */
        ulProducerCount++;
        if (xQueueSend(xDataQueue, &ulValue, portMAX_DELAY) == pdPASS) {
            if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
                uart_puts("[Producer] Item ");
                uart_putchar('0' + ulValue);
                uart_puts(" sent (queue may wake consumer)\r\n");
                xSemaphoreGive(xUartMutex);
            }
        }

        /* Yield to demonstrate cooperative scheduling */
        taskYIELD();
    }

    safe_print("[Producer] All items sent, task exiting\r\n");
    vTaskDelete(NULL);
}

/*-----------------------------------------------------------*/
/* Consumer Task - receives data from queue */

static void vConsumerTask(void *pvParameters)
{
    (void) pvParameters;
    uint32_t ulReceived;

    safe_print("[Consumer] Task started (higher priority)\r\n");

    while (ulConsumerCount < NUM_ITEMS) {
        /* Show we're waiting */
        safe_print("[Consumer] Waiting for queue data...\r\n");

        /* Receive from queue - blocks if empty */
        if (xQueueReceive(xDataQueue, &ulReceived, portMAX_DELAY) == pdPASS) {
            ulConsumerCount++;
            if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
                uart_puts("[Consumer] Received item ");
                uart_putchar('0' + ulReceived);
                uart_puts(" from queue\r\n");
                xSemaphoreGive(xUartMutex);
            }
        }
    }

    /* Print summary */
    if (xSemaphoreTake(xUartMutex, portMAX_DELAY) == pdTRUE) {
        uart_puts("\r\n");
        uart_puts("=== Demo Complete ===\r\n");
        uart_puts("Producer sent: ");
        uart_putchar('0' + ulProducerCount);
        uart_puts(" items\r\n");
        uart_puts("Consumer received: ");
        uart_putchar('0' + ulConsumerCount);
        uart_puts(" items\r\n");
        uart_puts("Queue + Mutex + Preemption: Working!\r\n");
        uart_puts("\r\nPASS\r\n");
        uart_puts("<<PASS>>\r\n");
        xSemaphoreGive(xUartMutex);
    }

    /* Disable interrupts and halt */
    __asm volatile("csrci mstatus, 0x08");
    for (;;) {
    }
}

/*-----------------------------------------------------------*/
/* Trap handler setup */

static void prvSetupTrapHandler(void)
{
    __asm volatile("csrw mtvec, %0" ::"r"(freertos_risc_v_trap_handler));
}

/*-----------------------------------------------------------*/
/* Main entry point */

int main(void)
{
    uart_puts("\r\n");
    uart_puts("========================================\r\n");
    uart_puts("  FreeRTOS Demo for FROST RISC-V CPU\r\n");
    uart_puts("========================================\r\n");
    uart_puts("Features demonstrated:\r\n");
    uart_puts("  - Multiple concurrent tasks\r\n");
    uart_puts("  - Inter-task queue communication\r\n");
    uart_puts("  - Mutex protecting shared UART\r\n");
    uart_puts("  - Preemptive priority scheduling\r\n");
    uart_puts("  - Blocking on queue empty/full\r\n");
    uart_puts("========================================\r\n\r\n");

    prvSetupTrapHandler();

    /* Create the mutex for UART protection */
    xUartMutex = xSemaphoreCreateMutex();
    if (xUartMutex == NULL) {
        uart_puts("[ERROR] Mutex creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created UART mutex\r\n");

    /* Create the data queue */
    xDataQueue = xQueueCreate(QUEUE_LENGTH, sizeof(uint32_t));
    if (xDataQueue == NULL) {
        uart_puts("[ERROR] Queue creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created data queue (depth=3)\r\n");

    /* Create producer task (priority 1) */
    if (xTaskCreate(vProducerTask, "Producer", TASK_STACK_SIZE, NULL, tskIDLE_PRIORITY + 1, NULL) !=
        pdPASS) {
        uart_puts("[ERROR] Producer task creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created Producer task (priority 1)\r\n");

    /* Create consumer task (priority 2 - higher, runs first when data available) */
    if (xTaskCreate(vConsumerTask, "Consumer", TASK_STACK_SIZE, NULL, tskIDLE_PRIORITY + 2, NULL) !=
        pdPASS) {
        uart_puts("[ERROR] Consumer task creation failed\r\n");
        for (;;)
            ;
    }
    uart_puts("[Main] Created Consumer task (priority 2)\r\n");

    uart_puts("[Main] Starting scheduler...\r\n\r\n");

    /* Start the scheduler - never returns */
    vTaskStartScheduler();

    /* Should never reach here */
    uart_puts("[ERROR] Scheduler returned!\r\n");
    for (;;)
        ;
    return 0;
}

/*-----------------------------------------------------------*/
/* Exception Handlers */

void freertos_risc_v_application_exception_handler(void)
{
    uint32_t mcause, mepc;
    __asm volatile("csrr %0, mcause" : "=r"(mcause));
    __asm volatile("csrr %0, mepc" : "=r"(mepc));
    uart_puts("\r\n[EXCEPTION] cause=");
    uart_putchar('0' + (mcause & 0xF));
    uart_puts(" at PC=0x");
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 7; i >= 0; i--) {
        uart_putchar(hex[(mepc >> (i * 4)) & 0xF]);
    }
    uart_puts("\r\n");
    for (;;)
        ;
}

void freertos_risc_v_application_interrupt_handler(void)
{
    uart_puts("\r\n[UNHANDLED IRQ]\r\n");
    for (;;)
        ;
}

void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void) xTask;
    (void) pcTaskName;
    uart_puts("[STACK OVERFLOW]\r\n");
    for (;;)
        ;
}

void vApplicationMallocFailedHook(void)
{
    uart_puts("[MALLOC FAILED]\r\n");
    for (;;)
        ;
}
