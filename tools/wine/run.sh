#!/bin/sh
# Run a command in the jolt-wine container (tools/wine/Containerfile).
#
# JOLT_SRC selects another checkout (default: this one). The checkout is mounted
# read-only and copied into the container's own /work on each run, so the
# Linux/Windows builds and caches never land in the host's working tree.
#
#   tools/wine/run.sh jolt-nt -e '(+ 1 2)'          # source mode under Wine
#   tools/wine/run.sh jolt-nt-script test/chez/win-platform-test.ss
#   tools/wine/run.sh sh -c 'jolt-nt-release && wine target/release/jolt.exe -e "(+ 1 2)"'
#   tools/wine/run.sh bash                           # a shell in /work
#
# jolt-nt is `wine scheme.exe --script host/chez/cli.ss`, the arrangement the
# windows-deps CI job runs; jolt-nt-script runs a chez --script gate the same way.
set -e
here=${JOLT_SRC:-$(cd "$(dirname "$0")/../.." && pwd)}
engine=${CONTAINER_ENGINE:-podman}
image=${JOLT_WINE_IMAGE:-jolt-wine}
tty=; [ -t 0 ] && tty=-it
exec "$engine" run --rm $tty --platform linux/amd64 \
  -v "$here":/src:ro -v jolt-wine-prefix:/root/.wine \
  -e JOLT_CHEZ_CSV=/opt/chez-nt/csv \
  "$image" sh -c '
    set -e
    tar -C /src --exclude=./target --exclude=./.git -cf - . | tar -C /work -xf -
    cat > /usr/local/bin/jolt-nt <<"SH"
#!/bin/sh
exec wine /opt/chez-nt/bin/scheme.exe --script host/chez/cli.ss "$@"
SH
    cat > /usr/local/bin/jolt-nt-script <<"SH"
#!/bin/sh
exec wine /opt/chez-nt/bin/scheme.exe --script "$@"
SH
    cat > /usr/local/bin/jolt-nt-release <<"SH"
#!/bin/sh
# cross-build target/release/jolt.exe (tools/cross-compile/README.md)
set -e
CHEZ_SRC=/opt/chez-src tools/cross-compile/make-pack.sh ta6nt /opt/pack >/dev/null
JOLT_TARGET_PACK=/opt/pack JOLT_TARGET_CC=x86_64-w64-mingw32-gcc \
  JOLT_VERSION=${JOLT_VERSION:-wine-dev} \
  make CHEZ=/usr/local/bin/scheme jolt-release JOLT_CROSS_TARGET=ta6nt
SH
    chmod +x /usr/local/bin/jolt-nt /usr/local/bin/jolt-nt-script /usr/local/bin/jolt-nt-release
    exec "$@"' sh "$@"
