#!/usr/bin/env python3
"""Page-cache control for the cold-start benchmark (bench/startup.sh COLD=1).

Two things the shell cannot do on its own:

  evict <file>     drop the file's pages from the page cache, so the next run of
                   it reads from storage. posix_fadvise(POSIX_FADV_DONTNEED) —
                   no root, no /proc/sys/vm/drop_caches, and it touches only
                   this one file rather than the whole machine's cache.
  resident <file>  report how much of the file is currently in the page cache,
                   via mincore(2). Run it after a cold invocation and the answer
                   is how many bytes that invocation actually had to read.

Both are advisory-adjacent and best effort: a failure prints to stderr and exits
non-zero, and the caller decides whether that is fatal.
"""
import ctypes
import os
import sys


def evict(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        # length 0 means "to end of file"
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
    finally:
        os.close(fd)


def resident(path):
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    libc.mmap.restype = ctypes.c_void_p
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                          ctypes.c_int, ctypes.c_int, ctypes.c_long]
    PROT_READ, MAP_SHARED = 1, 1
    size = os.path.getsize(path)
    fd = os.open(path, os.O_RDONLY)
    try:
        addr = libc.mmap(None, size, PROT_READ, MAP_SHARED, fd, 0)
        if addr in (None, ctypes.c_void_p(-1).value):
            raise OSError(ctypes.get_errno(), "mmap failed")
        pages = (size + 4095) // 4096
        vec = (ctypes.c_ubyte * pages)()
        try:
            if libc.mincore(ctypes.c_void_p(addr), ctypes.c_size_t(size), vec) != 0:
                raise OSError(ctypes.get_errno(), "mincore failed")
            # bit 0 of each byte is "this page is resident"
            return sum(1 for b in vec if b & 1) * 4096, size
        finally:
            libc.munmap(ctypes.c_void_p(addr), ctypes.c_size_t(size))
    finally:
        os.close(fd)


def main(argv):
    if len(argv) != 3:
        print("usage: pagecache.py evict|resident FILE", file=sys.stderr)
        return 2
    cmd, path = argv[1], argv[2]
    try:
        if cmd == "evict":
            evict(path)
        elif cmd == "resident":
            got, total = resident(path)
            print("%d %d" % (got, total))
        else:
            print("pagecache.py: unknown command %s" % cmd, file=sys.stderr)
            return 2
    except OSError as e:
        print("pagecache.py: %s: %s" % (cmd, e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
