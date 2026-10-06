/* Launch a command on K3's SpacemiT A100 HMP cluster.
 * Compile without V: the vendor kernel requires switching thread type before
 * the RISC-V vector context has ever been initialized. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s COMMAND [ARG...]\n", argv[0]);
    return 2;
  }
  int fd = open("/proc/set_ai_thread", O_WRONLY | O_CLOEXEC);
  if (fd < 0) {
    fprintf(stderr, "open /proc/set_ai_thread: %s\n", strerror(errno));
    return 3;
  }
  if (write(fd, "0\n", 2) != 2) {
    fprintf(stderr, "write /proc/set_ai_thread: %s\n", strerror(errno));
    close(fd);
    return 4;
  }
  close(fd);
  cpu_set_t allowed;
  if (sched_getaffinity(0, sizeof(allowed), &allowed)) {
    fprintf(stderr, "sched_getaffinity: %s\n", strerror(errno));
    return 5;
  }
  for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu)
    if (CPU_ISSET(cpu, &allowed) && cpu < 8) {
      fprintf(stderr, "A100 launch refused: regular CPU %d remains allowed\n", cpu);
      return 6;
    }
  execvp(argv[1], &argv[1]);
  fprintf(stderr, "exec %s: %s\n", argv[1], strerror(errno));
  return 7;
}
