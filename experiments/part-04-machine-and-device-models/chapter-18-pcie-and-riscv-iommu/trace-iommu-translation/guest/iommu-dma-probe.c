/* SPDX-License-Identifier: Apache-2.0 */

#include <arpa/inet.h>
#include <stddef.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <unistd.h>

static void write_all(const char *message)
{
    size_t remaining = strlen(message);

    while (remaining > 0) {
        ssize_t written = write(STDOUT_FILENO, message, remaining);

        if (written <= 0) {
            _exit(2);
        }
        message += written;
        remaining -= (size_t)written;
    }
}

int main(void)
{
    static const char payload[512] = "qemu-book-riscv-iommu-dma-probe";
    const struct sockaddr_in destination = {
        .sin_family = AF_INET,
        .sin_port = htons(9),
        .sin_addr = {
            .s_addr = htonl(0x0a000202U),
        },
    };
    int socket_fd = socket(AF_INET, SOCK_DGRAM, 0);

    write_all("iommu-probe:start\n");
    if (socket_fd < 0) {
        write_all("iommu-probe:socket-failed\n");
        return 1;
    }

    for (unsigned int iteration = 0; iteration < 32; iteration++) {
        if (sendto(socket_fd, payload, sizeof(payload), 0,
                   (const struct sockaddr *)&destination,
                   sizeof(destination)) < 0) {
            write_all("iommu-probe:send-failed\n");
            return 1;
        }
    }

    close(socket_fd);
    write_all("iommu-probe:sent\n");
    sync();
    reboot(RB_POWER_OFF);

    for (;;) {
        pause();
    }
}
