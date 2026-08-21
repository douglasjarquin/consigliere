#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int open_lock_file(const char *path) {
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) {
    return -1;
  }
  (void)fchmod(fd, 0600);
  return fd;
}

static int try_lock(int fd) {
  struct flock fl;
  memset(&fl, 0, sizeof(fl));
  fl.l_type = F_WRLCK;
  fl.l_whence = SEEK_SET;
  fl.l_start = 0;
  fl.l_len = 0;
  return fcntl(fd, F_SETLK, &fl);
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: cs_lock_probe hold|try PATH\n");
    return 2;
  }

  const char *cmd = argv[1];
  const char *path = argv[2];
  int fd = open_lock_file(path);
  if (fd < 0) {
    fprintf(stderr, "open: %s\n", strerror(errno));
    return 2;
  }

  if (try_lock(fd) != 0) {
    int err = errno;
    close(fd);
    if (err == EAGAIN || err == EACCES || err == EWOULDBLOCK) {
      fprintf(stdout, "busy\n");
      fflush(stdout);
      return 1;
    }
    fprintf(stderr, "fcntl: %s\n", strerror(err));
    return 2;
  }

  fprintf(stdout, "held\n");
  fflush(stdout);

  if (strcmp(cmd, "try") == 0) {
    close(fd);
    return 0;
  }

  if (strcmp(cmd, "hold") != 0) {
    close(fd);
    fprintf(stderr, "usage: cs_lock_probe hold|try PATH\n");
    return 2;
  }

  char buf[8];
  while (read(STDIN_FILENO, buf, sizeof(buf)) > 0) {
  }
  close(fd);
  return 0;
}
