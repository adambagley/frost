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

/**
 * Call Stress Test - Stress test for function calls with C extension enabled
 *
 * This test exercises the RISC-V C extension (compressed instructions) by
 * making many nested function calls. It verifies that compressed JAL/JALR
 * instructions correctly save return addresses and that the call stack
 * operates properly under stress. This is important because compressed
 * instructions have different encodings and PC-relative offsets.
 */

#include "uart.h"

volatile int call_count = 0;

// Simple function that just increments counter
void simple_func(void)
{
    call_count++;
}

// Function that makes a nested call
void nested_func(void)
{
    call_count++;
    simple_func();
}

// Function that makes multiple nested calls
void multi_nested(void)
{
    call_count++;
    simple_func();
    nested_func();
}

int main(void)
{
    uart_puts("Call stress test starting...\n");

    // Test 1: Many simple calls
    uart_puts("Test 1: 10 simple calls...");
    for (int i = 0; i < 10; i++) {
        simple_func();
    }
    uart_puts("OK\n");

    // Test 2: Nested calls
    uart_puts("Test 2: 10 nested calls...");
    for (int i = 0; i < 10; i++) {
        nested_func();
    }
    uart_puts("OK\n");

    // Test 3: Multi-nested calls
    uart_puts("Test 3: 10 multi-nested calls...");
    for (int i = 0; i < 10; i++) {
        multi_nested();
    }
    uart_puts("OK\n");

    // Test 4: Many printf calls
    uart_puts("Test 4: printf calls...\n");
    for (int i = 0; i < 5; i++) {
        uart_printf("  iteration %d\n", i);
    }
    uart_puts("OK\n");

    // Test 5: printf with various formats
    uart_puts("Test 5: format specifiers...\n");
    uart_printf("  int: %d\n", 12345);
    uart_printf("  hex: 0x%08x\n", 0xDEADBEEF);
    uart_printf("  str: %s\n", "hello");
    uart_puts("OK\n");

    uart_printf("\nTotal calls: %d\n", call_count);
    uart_puts("\n*** ALL TESTS PASSED ***\n");
    uart_puts("<<PASS>>\n");

    for (;;)
        ;
    return 0;
}
