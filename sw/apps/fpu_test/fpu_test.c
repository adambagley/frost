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
 * FPU Compliance Test
 *
 * Focuses on subnormal handling, fused multiply-add, rounding, and conversions.
 * Prints <<PASS>> on success or <<FAIL>> on any mismatch.
 */

#include "uart.h"
#include <stdint.h>

#define FP_POS_ZERO 0x00000000u
#define FP_NEG_ZERO 0x80000000u
#define FP_POS_ONE 0x3f800000u
#define FP_NEG_ONE 0xbf800000u
#define FP_POS_TWO 0x40000000u
#define FP_POS_HALF 0x3f000000u
#define FP_POS_FOUR 0x40800000u
#define FP_POS_ONE_HALF 0x3fc00000u
#define FP_NEG_ONE_HALF 0xbfc00000u
#define FP_POS_INF 0x7f800000u
#define FP_QNAN 0x7fc00000u

#define FP_MIN_NORMAL 0x00800000u
#define FP_MAX_SUBNORMAL 0x007fffffu
#define FP_MIN_SUBNORMAL 0x00000001u
#define FP_SUBNORMAL_TWO 0x00000002u
#define FP_SUBNORMAL_HALF_MIN_NORMAL 0x00400000u

static volatile uint32_t scratch[2];
static uint32_t tests_passed;
static uint32_t tests_failed;

static void test_u32(const char *name, uint32_t got, uint32_t expected)
{
    if (got == expected) {
        tests_passed++;
        uart_printf("\n[PASS] %s", name);
        return;
    }
    tests_failed++;
    uart_printf(
        "\n[FAIL] %s: got 0x%08x expected 0x%08x", name, (unsigned) got, (unsigned) expected);
}

static void test_i32(const char *name, int32_t got, int32_t expected)
{
    if (got == expected) {
        tests_passed++;
        uart_printf("\n[PASS] %s", name);
        return;
    }
    tests_failed++;
    uart_printf("\n[FAIL] %s: got %ld expected %ld", name, (long) got, (long) expected);
}

static inline uint32_t fadd_u32(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fadd.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t fsub_u32(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fsub.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t fmul_u32(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmul.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t fdiv_u32(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fdiv.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t fsqrt_u32(uint32_t a)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fsqrt.s ft1, ft0\n\t"
                     "fmv.x.w %0, ft1"
                     : "=r"(result)
                     : "r"(a)
                     : "ft0", "ft1");
    return result;
}

static inline uint32_t fmadd_u32(uint32_t a, uint32_t b, uint32_t c)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmv.w.x ft2, %3\n\t"
                     "fmadd.s ft3, ft0, ft1, ft2\n\t"
                     "fmv.x.w %0, ft3"
                     : "=r"(result)
                     : "r"(a), "r"(b), "r"(c)
                     : "ft0", "ft1", "ft2", "ft3");
    return result;
}

static inline uint32_t fmin_u32(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmin.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t fmax_u32(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fmax.s ft2, ft0, ft1\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t fcvt_s_w(int32_t a)
{
    uint32_t result;
    __asm__ volatile("fcvt.s.w ft0, %1\n\t"
                     "fmv.x.w %0, ft0"
                     : "=r"(result)
                     : "r"(a)
                     : "ft0");
    return result;
}

static inline int32_t fcvt_w_s(uint32_t a)
{
    int32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0"
                     : "=r"(result)
                     : "r"(a)
                     : "ft0");
    return result;
}

static inline int32_t fcvt_w_s_rup(uint32_t a)
{
    int32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rup"
                     : "=r"(result)
                     : "r"(a)
                     : "ft0");
    return result;
}

static inline int32_t fcvt_w_s_rdn(uint32_t a)
{
    int32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rdn"
                     : "=r"(result)
                     : "r"(a)
                     : "ft0");
    return result;
}

static inline int32_t fcvt_w_s_rtz(uint32_t a)
{
    int32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rtz"
                     : "=r"(result)
                     : "r"(a)
                     : "ft0");
    return result;
}

static inline int32_t fcvt_w_s_rmm(uint32_t a)
{
    int32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fcvt.w.s %0, ft0, rmm"
                     : "=r"(result)
                     : "r"(a)
                     : "ft0");
    return result;
}

static inline uint32_t fadd_rtz(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fadd.s ft2, ft0, ft1, rtz\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t fadd_rup(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fadd.s ft2, ft0, ft1, rup\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t fadd_rdn(uint32_t a, uint32_t b)
{
    uint32_t result;
    __asm__ volatile("fmv.w.x ft0, %1\n\t"
                     "fmv.w.x ft1, %2\n\t"
                     "fadd.s ft2, ft0, ft1, rdn\n\t"
                     "fmv.x.w %0, ft2"
                     : "=r"(result)
                     : "r"(a), "r"(b)
                     : "ft0", "ft1", "ft2");
    return result;
}

static inline uint32_t flw_fsw_roundtrip(uint32_t a)
{
    uint32_t result;
    scratch[0] = a;
    __asm__ volatile("flw ft0, 0(%1)\n\t"
                     "fsw ft0, 4(%1)\n\t"
                     "fence rw, rw\n\t"
                     "lw %0, 4(%1)"
                     : "=r"(result)
                     : "r"(&scratch[0])
                     : "ft0", "memory");
    return result;
}

int main(void)
{
    uart_printf("\n=== FPU Compliance Test ===\n");

    __asm__ volatile("csrw frm, zero");
    __asm__ volatile("csrw fflags, zero");

    uart_printf("\n-- Load/Store --\n");
    test_u32("fsw/flw roundtrip subnormal", flw_fsw_roundtrip(FP_MIN_SUBNORMAL), FP_MIN_SUBNORMAL);

    uart_printf("\n-- Add/Sub --\n");
    test_u32(
        "fadd min_sub + min_sub", fadd_u32(FP_MIN_SUBNORMAL, FP_MIN_SUBNORMAL), FP_SUBNORMAL_TWO);
    test_u32("fadd max_sub + min_sub", fadd_u32(FP_MAX_SUBNORMAL, FP_MIN_SUBNORMAL), FP_MIN_NORMAL);
    test_u32(
        "fsub min_normal - max_sub", fsub_u32(FP_MIN_NORMAL, FP_MAX_SUBNORMAL), FP_MIN_SUBNORMAL);

    uart_printf("\n-- Multiply --\n");
    test_u32("fmul min_normal * 0.5",
             fmul_u32(FP_MIN_NORMAL, FP_POS_HALF),
             FP_SUBNORMAL_HALF_MIN_NORMAL);
    test_u32("fmul min_sub * 2.0", fmul_u32(FP_MIN_SUBNORMAL, FP_POS_TWO), FP_SUBNORMAL_TWO);

    uart_printf("\n-- Divide --\n");
    test_u32(
        "fdiv min_normal / 2.0", fdiv_u32(FP_MIN_NORMAL, FP_POS_TWO), FP_SUBNORMAL_HALF_MIN_NORMAL);
    test_u32("fdiv min_sub / 2.0", fdiv_u32(FP_MIN_SUBNORMAL, FP_POS_TWO), FP_POS_ZERO);

    uart_printf("\n-- Sqrt --\n");
    test_u32("fsqrt 4.0", fsqrt_u32(FP_POS_FOUR), FP_POS_TWO);
    test_u32("fsqrt -1 -> qNaN", fsqrt_u32(FP_NEG_ONE), FP_QNAN);

    uart_printf("\n-- Fused Multiply-Add --\n");
    /* FMA case where fused result differs from mul+add */
    test_u32("fmadd fused rounding", fmadd_u32(0xbf51b96du, 0x407985cau, 0x4077c566u), 0x3f2d69c1u);

    uart_printf("\n-- Min/Max --\n");
    test_u32("fmin +0,-0 -> -0", fmin_u32(FP_POS_ZERO, FP_NEG_ZERO), FP_NEG_ZERO);
    test_u32("fmax +0,-0 -> +0", fmax_u32(FP_POS_ZERO, FP_NEG_ZERO), FP_POS_ZERO);
    test_u32("fmin NaN,1 -> 1", fmin_u32(FP_QNAN, FP_POS_ONE), FP_POS_ONE);
    test_u32("fmax NaN,1 -> 1", fmax_u32(FP_QNAN, FP_POS_ONE), FP_POS_ONE);

    uart_printf("\n-- Conversions --\n");
    test_u32("fcvt.s.w 16777217", fcvt_s_w(16777217), 0x4b800000u);
    test_i32("fcvt.w.s 1.5 -> 2", fcvt_w_s(FP_POS_ONE_HALF), 2);
    test_i32("fcvt.w.s -1.5 -> -2", fcvt_w_s(FP_NEG_ONE_HALF), -2);
    test_i32("fcvt.w.s min_sub (RUP)", fcvt_w_s_rup(FP_MIN_SUBNORMAL), 1);

    uart_printf("\n-- Rounding Modes (FCVT.W.S) --\n");
    /* 1.5 with different rounding modes */
    test_i32("fcvt.w.s 1.5 RNE -> 2", fcvt_w_s(FP_POS_ONE_HALF), 2);     /* ties to even */
    test_i32("fcvt.w.s 1.5 RTZ -> 1", fcvt_w_s_rtz(FP_POS_ONE_HALF), 1); /* toward zero */
    test_i32("fcvt.w.s 1.5 RDN -> 1", fcvt_w_s_rdn(FP_POS_ONE_HALF), 1); /* toward -inf */
    test_i32("fcvt.w.s 1.5 RUP -> 2", fcvt_w_s_rup(FP_POS_ONE_HALF), 2); /* toward +inf */
    test_i32("fcvt.w.s 1.5 RMM -> 2", fcvt_w_s_rmm(FP_POS_ONE_HALF), 2); /* ties to max mag */

    /* -1.5 with different rounding modes */
    test_i32("fcvt.w.s -1.5 RNE -> -2", fcvt_w_s(FP_NEG_ONE_HALF), -2);
    test_i32("fcvt.w.s -1.5 RTZ -> -1", fcvt_w_s_rtz(FP_NEG_ONE_HALF), -1);
    test_i32("fcvt.w.s -1.5 RDN -> -2", fcvt_w_s_rdn(FP_NEG_ONE_HALF), -2);
    test_i32("fcvt.w.s -1.5 RUP -> -1", fcvt_w_s_rup(FP_NEG_ONE_HALF), -1);
    test_i32("fcvt.w.s -1.5 RMM -> -2", fcvt_w_s_rmm(FP_NEG_ONE_HALF), -2);

    /* 2.5 - tests ties-to-even vs ties-to-max-magnitude */
#define FP_POS_TWO_HALF 0x40200000u                                      /* 2.5f */
#define FP_NEG_TWO_HALF 0xc0200000u                                      /* -2.5f */
    test_i32("fcvt.w.s 2.5 RNE -> 2", fcvt_w_s(FP_POS_TWO_HALF), 2);     /* even is 2 */
    test_i32("fcvt.w.s 2.5 RMM -> 3", fcvt_w_s_rmm(FP_POS_TWO_HALF), 3); /* max mag is 3 */
    test_i32("fcvt.w.s -2.5 RNE -> -2", fcvt_w_s(FP_NEG_TWO_HALF), -2);
    test_i32("fcvt.w.s -2.5 RMM -> -3", fcvt_w_s_rmm(FP_NEG_TWO_HALF), -3);

    uart_printf("\n-- Rounding Modes (FADD.S) --\n");
    /* Test rounding in addition: 1.0 + tiny value that causes rounding */
    /* 1.0 + 2^-24 = 1.0000000596... which rounds differently */
#define FP_TINY_POSITIVE 0x33800000u /* 2^-24 = 5.96e-8 */
    /* Adding 1.0 + 2^-24:
     * - RNE: rounds to 1.0 (tie goes to even, LSB of 1.0 mantissa is 0)
     * - RTZ: truncates to 1.0
     * - RDN: rounds down to 1.0
     * - RUP: rounds up to 1.0 + ulp = 0x3f800001
     */
    test_u32("fadd 1+tiny RNE -> 1", fadd_u32(FP_POS_ONE, FP_TINY_POSITIVE), FP_POS_ONE);
    test_u32("fadd 1+tiny RTZ -> 1", fadd_rtz(FP_POS_ONE, FP_TINY_POSITIVE), FP_POS_ONE);
    test_u32("fadd 1+tiny RDN -> 1", fadd_rdn(FP_POS_ONE, FP_TINY_POSITIVE), FP_POS_ONE);
    test_u32("fadd 1+tiny RUP -> 1+ulp", fadd_rup(FP_POS_ONE, FP_TINY_POSITIVE), 0x3f800001u);

    /* Test negative: -1.0 - tiny should round differently */
    test_u32("fadd -1-tiny RDN -> -1-ulp", fadd_rdn(FP_NEG_ONE, 0xb3800000u), 0xbf800001u);
    test_u32("fadd -1-tiny RUP -> -1", fadd_rup(FP_NEG_ONE, 0xb3800000u), FP_NEG_ONE);

    uart_printf("\nResults: %lu passed, %lu failed\n",
                (unsigned long) tests_passed,
                (unsigned long) tests_failed);
    if (tests_failed == 0) {
        uart_printf("\n<<PASS>>\n");
    } else {
        uart_printf("\n<<FAIL>>\n");
    }

    for (;;)
        ;

    return 0;
}
