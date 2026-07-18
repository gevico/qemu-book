/* SPDX-License-Identifier: Apache-2.0 */

#include <stdint.h>

#define UART_TX ((volatile uint8_t *)0x10000000UL)
#define TEST_FINISHER ((volatile uint32_t *)0x00100000UL)
#define FINISHER_PASS 0x5555U
#define FINISHER_FAIL 0x3333U

typedef unsigned long (*generated_fn)(void);

static volatile uint32_t generated_code[2]
    __attribute__((aligned(4096), section(".smc")));

static void putchar(char value)
{
    *UART_TX = (uint8_t)value;
}

static void install_return_value(uint32_t value)
{
    /* addi a0, zero, value; ret */
    generated_code[0] = (value << 20) | (10U << 7) | 0x13U;
    generated_code[1] = 0x00008067U;
    __asm__ volatile("fence.i" ::: "memory");
}

void guest_main(void)
{
    generated_fn run = (generated_fn)(uintptr_t)generated_code;
    unsigned long first;
    unsigned long second;

    install_return_value(1);
    first = run();

    install_return_value(2);
    second = run();

    putchar((char)('0' + first));
    putchar((char)('0' + second));
    putchar('\n');

    *TEST_FINISHER = first == 1 && second == 2
                     ? FINISHER_PASS : FINISHER_FAIL;

    for (;;) {
        __asm__ volatile("wfi");
    }
}
