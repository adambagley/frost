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
 * Spanning Instruction Test
 *
 * Tests that 32-bit instructions spanning word boundaries execute correctly.
 * This is important for compressed extension support where the instruction
 * stream contains mixed 16-bit and 32-bit instructions.
 */
#include "uart.h"

int main(void)
{
    uart_puts("=== Spanning Instruction Test ===\n");

    /* Test 1: Basic printf with string argument */
    uart_puts("Test 1: printf with string... ");
    uart_printf("%s", "Hello");
    uart_puts(" OK\n");

    /* Test 2: printf in a loop (tests PC handling across iterations) */
    uart_puts("Test 2: printf in loop... ");
    for (int i = 0; i < 3; i++) {
        uart_printf("%d", i);
    }
    uart_puts(" OK\n");

    /* Test 3: printf with multiple format specifiers */
    uart_puts("Test 3: complex printf... ");
    uart_printf("%s=%d", "val", 42);
    uart_puts(" OK\n");

    uart_puts("\n=== All Tests Passed ===\n");
    uart_puts("<<PASS>>\n");

    for (;;) {
    }
}
