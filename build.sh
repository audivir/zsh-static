#!/usr/bin/env bash
# Usage: ./build.sh [--jobs N] [--clean] [--static]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
CLEAN=0
STATIC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --static)
      STATIC=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

GLIBC_VER=2.17

# terminal entries compiled into ncurses, used when the system terminfo database lacks them.
FALLBACKS=(
  ansi dumb linux vt100 vt220
  xterm xterm-256color xterm-color
  screen screen-256color screen.xterm-256color
  tmux tmux-256color
  rxvt rxvt-256color
  alacritty kitty foot wezterm
)
TERMINFO_DIRS_DEFAULT=/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo:/usr/share/lib/terminfo

OS="$(uname -s)"
ARCH="$(uname -m)"
[ "$ARCH" = arm64 ] && ARCH=aarch64

SUFFIX=""
[ "$STATIC" = 1 ] && SUFFIX="-static"
WORK="$ROOT_DIR/build$SUFFIX"
PREFIX="$WORK/deps"
HOST="$WORK/host"
DIST="$ROOT_DIR/dist$SUFFIX"

case "$OS-$ARCH" in
  Linux-x86_64 | Linux-aarch64)
    ZIG_TARGET=$ARCH-linux-gnu.$GLIBC_VER
    [ "$STATIC" = 1 ] && ZIG_TARGET=$ARCH-linux-musl
    ;;
  Darwin-aarch64 | Darwin-x86_64)
    ZIG_TARGET=native
    ;;
  *)
    echo "unsupported host $OS-$ARCH" >&2
    exit 1
    ;;
esac
if [ "$OS" != Linux ] && [ "$STATIC" = 1 ]; then
  echo "--static is only supported on Linux" >&2
  exit 1
fi

MAKE="${MAKE:-$(command -v gmake || command -v make)}"
"$MAKE" --version 2>/dev/null | grep -q 'GNU Make' || {
  echo "GNU make required" >&2
  exit 1
}

if [ "$ZIG_TARGET" = native ]; then export CC="zig cc"; else export CC="zig cc -target $ZIG_TARGET"; fi
export AR="zig ar"
export RANLIB="zig ranlib"
[ "$OS" = Linux ] && export LD="zig ld.lld"

if [ "$CLEAN" = 1 ]; then
  echo ">>> cleaning $WORK and $DIST"
  rm -rf "$WORK" "$DIST"
fi
mkdir -p "$WORK/src" "$PREFIX/include" "$PREFIX/lib"

cd "$WORK/src"

prepare() {
  [ -d "$1" ] && return
  if [ ! -f "$ROOT_DIR/vendor/$1/.git" ] && [ ! -d "$ROOT_DIR/vendor/$1/.git" ]; then
    echo "vendor/$1 is missing, run: git submodule update --init --depth 1" >&2
    exit 1
  fi
  echo ">>> preparing $1 ($(git -C "$ROOT_DIR/vendor/$1" describe --tags 2>/dev/null || echo unknown))"
  cp -R "$ROOT_DIR/vendor/$1" "$1"
  rm -rf "$1/.git"
}

prepare ncurses
prepare zsh

NCURSES_COMMON=(
  --without-shared --with-normal --without-debug
  --without-cxx --without-cxx-binding --without-ada
  --without-tests --without-manpages
  --enable-widec --disable-db-install
)

# builds tic and infocmp for the build machine to compile the fallback entries.
if [ ! -x "$HOST/bin/infocmp" ]; then
  echo ">>> ncurses (host tic/infocmp)"
  rm -rf ncurses-host
  cp -R ncurses ncurses-host
  (
    cd ncurses-host
    # tic runs on the build machine, so it is built for it rather than for the target.
    CC="zig cc" ./configure --prefix="$HOST" "${NCURSES_COMMON[@]}" --with-progs
    "$MAKE" -j"$JOBS"
    "$MAKE" install.progs
  )
fi

echo ">>> ncurses"
(
  cd ncurses
  [ -f Makefile ] && "$MAKE" distclean >/dev/null 2>&1 || true
  ./configure \
    --prefix="$PREFIX" \
    "${NCURSES_COMMON[@]}" \
    --without-progs --with-termlib \
    --with-default-terminfo-dir=/usr/share/terminfo \
    --with-terminfo-dirs="$TERMINFO_DIRS_DEFAULT" \
    --with-fallbacks="$(
      IFS=,
      echo "${FALLBACKS[*]}"
    )" \
    --with-tic-path="$HOST/bin/tic" \
    --with-infocmp-path="$HOST/bin/infocmp"
  "$MAKE" -j"$JOBS" libs
  "$MAKE" install.libs install.includes
)

ZSH_VERSION="$(sed -n 's/^VERSION=//p' zsh/Config/version.mk)"
FPATH_DEFAULT="/usr/local/share/zsh/$ZSH_VERSION/functions"

echo ">>> zsh $ZSH_VERSION"
(
  cd zsh
  [ -f configure ] || ./Util/preconfig >/dev/null

  # zsh compiles the dir of its functions in. Instead, it takes the dir relative to its binary, from
  # /proc/self/exe on Linux and proc_pidpath on macOS, so the install can live anywhere; modules
  # are linked in, so their dir is unused.
  cat >../zshpaths.h <<END
#define MODULE_DIR "/dev/null"
#define FPATH_DIR zsh_static_fpath_dir()
extern char *zsh_static_fpath_dir(void);
END
  if ! grep -q zsh_static_fpath_dir Src/init.c; then
    sed -i.orig 's|mv -f zshpaths.h.tmp zshpaths.h|cp -f ../../zshpaths.h ./|' Src/zsh.mdd
    cat >>Src/init.c <<END

#ifdef __APPLE__
#include <libproc.h>
#endif

/* the functions dir of an install whose binary is <prefix>/bin/zsh. */
char *
zsh_static_fpath_dir(void)
{
    static char *dir;
    char exe[4096];
    char *slash;
    int i;
    ssize_t n;

    if (dir)
    return dir;
#ifdef __APPLE__
    n = proc_pidpath(getpid(), exe, sizeof(exe)) > 0 ? (ssize_t)strlen(exe) : -1;
#else
    n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
#endif
    if (n > 0) {
    exe[n] = '\0';
    for (i = 0; i < 2 && (slash = strrchr(exe, '/')); i++)
        *slash = '\0';
    if (i == 2) {
        dir = bicat(exe, "/share/zsh/$ZSH_VERSION/functions");
        return dir;
    }
    }
    dir = ztrdup("$FPATH_DEFAULT");
    return dir;
}
END
  fi

  [ -f Makefile ] && "$MAKE" distclean >/dev/null 2>&1 || true
  LDFLAGS="-s -L$PREFIX/lib"
  [ "$STATIC" = 1 ] && LDFLAGS="-static $LDFLAGS"
  # the startup files in /etc of the system zsh are not read, so the install is the same everywhere.
  # tcsetpgrp cannot be probed without a terminal.
  ./configure \
    --prefix=/usr/local \
    --disable-etcdir --disable-site-fndir --disable-site-scriptdir \
    --disable-dynamic --disable-gdbm --disable-pcre --disable-cap \
    --enable-multibyte --enable-unicode9 --with-tcsetpgrp \
    --with-term-lib="tinfow ncursesw" \
    CFLAGS="-Os" CPPFLAGS="-I$PREFIX/include -I$PREFIX/include/ncursesw" LDFLAGS="$LDFLAGS"
  # links every module into the binary, apart from those needing libraries that are not built.
  sed -i.orig -e 's/link=dynamic/link=static/' -e 's/link=no/link=static/' \
    -e '/name=zsh\/db\/gdbm /s/link=static/link=no/' -e '/name=zsh\/pcre /s/link=static/link=no/' \
    -e '/name=zsh\/cap /s/link=static/link=no/' -e '/name=zsh\/attr /s/link=static/link=no/' \
    config.modules
  "$MAKE" -j"$JOBS"
  rm -rf "$WORK/out"
  "$MAKE" DESTDIR="$WORK/out" install.bin install.modules install.fns
)

rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/share/zsh"
cp "$WORK/out/usr/local/bin/zsh" "$DIST/bin/zsh"
cp -R "$WORK/out/usr/local/share/zsh/$ZSH_VERSION" "$DIST/share/zsh/"

# building the man pages needs yodl, so take the ones of the release tarball, which has them built.
echo ">>> man pages"
TARBALL="zsh-$ZSH_VERSION.tar.xz"
mkdir -p "$DIST/share/man/man1"
(
  cd "$WORK"
  [ -f "$TARBALL" ] || curl -fsSLO "https://www.zsh.org/pub/$TARBALL"
  want="$(curl -fsSL https://www.zsh.org/pub/MD5SUM | awk -v f="$TARBALL" '$2 == f { print $1 }')"
  got="$( (md5sum "$TARBALL" 2>/dev/null || md5 -r "$TARBALL") | awk '{ print $1 }')"
  [ -n "$want" ] && [ "$want" = "$got" ] || {
    echo "checksum mismatch for $TARBALL: got $got, want $want" >&2
    exit 1
  }
  rm -rf "zsh-$ZSH_VERSION"
  tar -xJf "$TARBALL" "zsh-$ZSH_VERSION/Doc"
  cp "zsh-$ZSH_VERSION"/Doc/*.1 "$DIST/share/man/man1/"
)

ZSH_BIN="$DIST/bin/zsh"
echo
echo ">>> done: $ZSH_BIN"
"$ZSH_BIN" --version
if [ "$OS" = Linux ]; then
  if [ "$STATIC" = 1 ]; then
    # static musl libc embeds the loader path as a string, so check for an interpreter header.
    if readelf -l "$ZSH_BIN" | grep -q INTERP; then
      echo "WARNING: zsh references a dynamic loader, not fully static" >&2
    else
      echo "fully static"
    fi
  elif LC_ALL=C grep -a -q -E 'lib(ncurses|tinfo|pcre|gdbm|cap)[a-z]*\.so' "$ZSH_BIN"; then
    echo "WARNING: zsh links a dependency dynamically, not only glibc" >&2
  else
    echo "only glibc is dynamic"
  fi
else
  otool -L "$ZSH_BIN"
fi
