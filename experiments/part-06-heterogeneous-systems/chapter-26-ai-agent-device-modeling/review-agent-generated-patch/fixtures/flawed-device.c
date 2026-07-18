/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Deliberately flawed, non-buildable QEMU-style review fixture.
 * Never use this file as a device implementation.
 */

typedef struct FlawedDeviceState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;
    qemu_irq irq;
    QEMUTimer *completion_timer;
    uint64_t guest_address;
    uint32_t guest_length;
    uint8_t *request_buffer;
} FlawedDeviceState;

static void flawed_complete(void *opaque)
{
    FlawedDeviceState *s = opaque;

    /* No request generation check: a pre-reset timer may complete new state. */
    qemu_set_irq(s->irq, 1);
}

static void flawed_write(void *opaque, hwaddr offset, uint64_t value,
                         unsigned size)
{
    FlawedDeviceState *s = opaque;

    /* Access size and alignment are ignored. */
    switch (offset) {
    case 0x08:
        s->guest_address = value;
        break;
    case 0x10:
        s->guest_length = value;
        break;
    case 0x18:
        /* Guest length is unbounded and guest arithmetic is unchecked. */
        s->request_buffer = g_malloc(s->guest_length * 16);
        address_space_read(&address_space_memory, s->guest_address,
                           MEMTXATTRS_UNSPECIFIED, s->request_buffer,
                           s->guest_length * 16);
        timer_mod(s->completion_timer, qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL));
        break;
    default:
        break;
    }
}

static void flawed_reset(DeviceState *device)
{
    FlawedDeviceState *s = FLAWED_DEVICE(device);

    /* Timer, IRQ, request buffer, and in-flight DMA lifetime are ignored. */
    s->guest_length = 0;
}

/* The fixture intentionally omits unrealize, VMState, and negative qtests. */
