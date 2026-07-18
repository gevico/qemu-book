/* SPDX-License-Identifier: Apache-2.0 */

#include <stdint.h>

#define UART_TX ((volatile uint8_t *)0x10000000UL)

static volatile uint64_t counter;

static void putchar(char value)
{
    *UART_TX = (uint8_t)value;
}

static void print_counter(uint64_t value)
{
    static const char hex[] = "0123456789abcdef";

    for (const char *cursor = "counter="; *cursor; cursor++) {
        putchar(*cursor);
    }
    for (int shift = 60; shift >= 0; shift -= 4) {
        putchar(hex[(value >> shift) & 0xf]);
    }
    putchar('\n');
}

void guest_main(void)
{
    for (;;) {
        counter++;
        if ((counter & 0x3fffffUL) == 0) {
            print_counter(counter);
        }
    }
}
