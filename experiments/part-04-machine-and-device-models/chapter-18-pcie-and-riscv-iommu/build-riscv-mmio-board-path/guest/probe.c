/* SPDX-License-Identifier: Apache-2.0 */

#include <stdint.h>

#define TEST_FINISHER_BASE 0x00100000UL
#define FINISHER_FAIL      0x3333U
#define FINISHER_PASS      0x5555U

#define DEMO_BASE          0x10010000UL
#define PLIC_PENDING_BASE  0x0c001000UL
#define DEMO_IRQ           12

#define REG_ID             0x00
#define REG_CONTROL        0x04
#define REG_STATUS         0x08
#define REG_DATA           0x0c
#define REG_DOORBELL       0x10

#define ID_VALUE           0x51424d4dU
#define CONTROL_ENABLE     (1U << 0)
#define CONTROL_IRQ_ENABLE (1U << 1)
#define CONTROL_MASK       0x3U
#define STATUS_PENDING     (1U << 0)
#define DATA_MASK          0xffU

static uint32_t mmio_read32(uintptr_t address)
{
    uint32_t value = *(volatile uint32_t *)address;

    __asm__ volatile("fence iorw, iorw" ::: "memory");
    return value;
}

static void mmio_write32(uintptr_t address, uint32_t value)
{
    *(volatile uint32_t *)address = value;
    __asm__ volatile("fence iorw, iorw" ::: "memory");
}

static void finish(uint32_t status, uint32_t code)
{
    mmio_write32(TEST_FINISHER_BASE, (code << 16) | status);
    for (;;) {
        __asm__ volatile("wfi");
    }
}

static void check(int condition, uint32_t code)
{
    if (!condition) {
        finish(FINISHER_FAIL, code);
    }
}

void main(void)
{
    check(mmio_read32(DEMO_BASE + REG_ID) == ID_VALUE, 1);
    check(mmio_read32(DEMO_BASE + REG_CONTROL) == 0, 2);
    check(mmio_read32(DEMO_BASE + REG_STATUS) == 0, 3);
    check(mmio_read32(DEMO_BASE + REG_DATA) == 0, 4);

    mmio_write32(DEMO_BASE + REG_CONTROL, 0xffffffffU);
    check(mmio_read32(DEMO_BASE + REG_CONTROL) == CONTROL_MASK, 5);
    mmio_write32(DEMO_BASE + REG_DATA, 0xffffffffU);
    check(mmio_read32(DEMO_BASE + REG_DATA) == DATA_MASK, 6);

    mmio_write32(DEMO_BASE + REG_CONTROL,
                 CONTROL_ENABLE | CONTROL_IRQ_ENABLE);
    mmio_write32(DEMO_BASE + REG_DOORBELL, 1);
    check(mmio_read32(DEMO_BASE + REG_STATUS) == STATUS_PENDING, 7);
    check(mmio_read32(PLIC_PENDING_BASE) & (1U << DEMO_IRQ), 8);

    mmio_write32(DEMO_BASE + REG_STATUS, STATUS_PENDING);
    check(mmio_read32(DEMO_BASE + REG_STATUS) == 0, 9);

    finish(FINISHER_PASS, 0);
}
