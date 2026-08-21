#include <errno.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    return 127;
  }

  /* Prefer a new session. Port children are often already process-group
     leaders, in which case setsid() returns EPERM; then take our own
     process group so signaling -pid cannot hit BEAM. */
  if (setsid() == (pid_t)-1) {
    if (setpgid(0, 0) == -1 && errno != EPERM) {
      return 126;
    }
  }

  execvp(argv[1], argv + 1);
  return 127;
}
