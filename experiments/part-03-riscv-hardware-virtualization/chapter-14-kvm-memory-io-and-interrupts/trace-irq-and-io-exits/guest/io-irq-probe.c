/* SPDX-License-Identifier: Apache-2.0 */

#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/time.h>
#include <unistd.h>

static volatile sig_atomic_t timer_fired;

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

static void timer_handler(int signal_number)
{
    (void)signal_number;
    timer_fired = 1;
}

int main(void)
{
    const struct sigaction action = {
        .sa_handler = timer_handler,
    };
    const struct itimerval timer = {
        .it_value = {
            .tv_sec = 0,
            .tv_usec = 25000,
        },
    };

    write_all("probe:uart-before\n");
    if (sigaction(SIGALRM, &action, NULL) != 0 ||
        setitimer(ITIMER_REAL, &timer, NULL) != 0) {
        write_all("probe:timer-setup-failed\n");
        return 1;
    }

    while (!timer_fired) {
        pause();
    }
    write_all("probe:timer-fired\n");
    sync();
    reboot(RB_POWER_OFF);

    for (;;) {
        pause();
    }
}
