#!/bin/sh
# Run a command as the Termux user in termux/termux-docker, the image the
# Android (bionic) CI job builds and gates jolt in (#943, ci/termux-build.sh).
# arm64 only: on Apple silicon the podman machine runs it natively.
#
# JOLT_SRC selects another checkout (default: this one). It is mounted read-only
# and copied to ~/jolt-<checkout name> on each run, so builds never land in the
# host tree. Two named volumes persist between runs: the Termux prefix (so the
# apt upgrade and packages are paid once) and the home directory, where each
# copy's .cache points at one shared ~/cache — the pinned Chez is provisioned
# once for every checkout.
#
#   tools/termux/run.sh make jolt-release           # build target/release/jolt
#   tools/termux/run.sh target/release/jolt -e '(+ 1 2)'
#   tools/termux/run.sh make interruptnest           # any gate, as bionic-ci runs it
#   JOLT_SRC=../jolt-1305 tools/termux/run.sh make jolt-release
#   tools/termux/run.sh sh                           # a shell in the copy
#
# JOLT_TERMUX_FRESH=1 drops both volumes first.
set -e
here=$(cd "${JOLT_SRC:-$(dirname "$0")/../..}" && pwd)
name=$(basename "$here")
engine=${CONTAINER_ENGINE:-podman}
image=${JOLT_TERMUX_IMAGE:-docker.io/termux/termux-docker:aarch64}
usr=jolt-termux-usr
home=jolt-termux-home
if [ "${JOLT_TERMUX_FRESH:-}" = 1 ]; then
  "$engine" volume rm -f "$usr" "$home" >/dev/null 2>&1 || true
fi
tty=; [ -t 0 ] && tty=-it

# The image's entrypoint drops to the Termux user with env -i, so settings go
# in through the script's arguments, never -e. Setup runs as that user too.
exec "$engine" run --rm $tty --platform linux/arm64 \
  -v "$here":/src:ro \
  -v "$usr":/data/data/com.termux/files/usr \
  -v "$home":/data/data/com.termux/files/home \
  --entrypoint /system/bin/sh "$image" \
  -c 'mkdir -p /tmp && chmod 1777 /tmp && exec /entrypoint.sh sh -c "$0" termux "$@"' '
    set -e
    name=$1; shift
    # no .git in the copy, so the version comes from here, as tools/wine does
    export JOLT_VERSION="${JOLT_VERSION:-termux-dev}"
    if [ -z "${LD_PRELOAD:-}" ] && [ -f "$PREFIX/lib/libtermux-exec-ld-preload.so" ]; then
      export LD_PRELOAD="$PREFIX/lib/libtermux-exec-ld-preload.so"
    fi
    export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
    mkdir -p "$TMPDIR"
    # Packages: ci/termux-build.sh'"'"'s list, installed once per prefix volume.
    if [ ! -f "$PREFIX/.jolt-termux-ready" ]; then
      echo "deb https://packages-cf.termux.dev/apt/termux-main stable main" > "$PREFIX/etc/apt/sources.list"
      apt-get update
      apt-get -y -o Dpkg::Options::=--force-confnew upgrade
      apt-get install -y clang make git curl which xxd binutils zip perl libsqlite \
        ncurses libuuid libiconv
      touch "$PREFIX/.jolt-termux-ready"
    fi
    work="$HOME/jolt-$name"
    mkdir -p "$work" "$HOME/cache"
    # A fresh copy each run, keeping the build tree: target/ is make'"'"'s to
    # judge stale, and a removed source file must not linger in the copy.
    find "$work" -mindepth 1 -maxdepth 1 ! -name target ! -name .cache -exec rm -rf {} +
    (cd /src && tar --exclude=./target --exclude=./.git --exclude=./.cache -cf - .) | tar -C "$work" -xf -
    [ -L "$work/.cache" ] || { rm -rf "$work/.cache"; ln -s "$HOME/cache" "$work/.cache"; }
    cd "$work"
    exec "$@"' "$name" "$@"
