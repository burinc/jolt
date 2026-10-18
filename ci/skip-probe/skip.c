#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) { perror("open"); return 1; }
  errno = 0;
  off_t r = lseek(fd, LLONG_MAX, SEEK_CUR);
  printf("lseek(cur + LLONG_MAX) = %lld errno=%d (%s)\n", (long long)r, errno, r < 0 ? strerror(errno) : "-");
  char buf[8192];
  errno = 0;
  ssize_t n = read(fd, buf, 1);
  printf("read(1) after it = %zd errno=%d (%s)\n", n, errno, n < 0 ? strerror(errno) : "-");
  errno = 0;
  n = read(fd, buf, sizeof buf);
  printf("read(8192) after it = %zd errno=%d (%s)\n", n, errno, n < 0 ? strerror(errno) : "-");
  return 0;
}
