#!/usr/bin/env bash
# Usage: ./tests/run_smoke_tests.sh [--static] [--dist DIR]
# shellcheck disable=SC2016 # $ in the zsh code is expanded by zsh, not this shell.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT_DIR/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)
      DIST="$ROOT_DIR/dist-static"
      shift
      ;;
    --dist)
      DIST="$(cd "$2" && pwd)"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ZSH="$DIST/bin/zsh"
version="$("$ZSH" --version)"
echo "$version" | grep -q '^zsh ' || fail "zsh --version"
pass "$version"

# a moved copy, run through a symlink, finds the functions next to itself.
cp -R "$DIST" "$TMP/moved"
ln -s "$TMP/moved/bin/zsh" "$TMP/zsh-link"
ZSH="$TMP/zsh-link"
want="$(cd "$TMP/moved" && pwd -P)/share/zsh/$("$ZSH" -fc 'print -r -- $ZSH_VERSION')/functions"
[ "$("$ZSH" -fc 'print -r -- $fpath[1]')" = "$want" ] || fail "fpath is not inside the moved tree"
"$ZSH" -fc 'autoload -U compinit && compinit -u -d "$HOME/.zcompdump" && (( $+_comps[git] ))' \
  || fail "compinit"
pass "relocatable fpath, compinit"

modules=(
  zsh/complist zsh/computil zsh/curses zsh/datetime zsh/files zsh/mathfunc zsh/net/tcp
  zsh/parameter zsh/regex zsh/stat zsh/system zsh/terminfo zsh/zle zsh/zpty zsh/zutil
)
for module in "${modules[@]}"; do
  "$ZSH" -fc "zmodload $module" || fail "module $module"
done
pass "built-in modules"

# without a reachable terminfo database, the entries compiled into ncurses are used.
TERMINFO=/nonexistent TERMINFO_DIRS=/nonexistent TERM=xterm-256color \
  "$ZSH" -fc 'zmodload zsh/terminfo && [[ -n $terminfo[clear] ]]' \
  || fail "built-in terminfo entry"
pass "built-in terminfo"

# drives an interactive shell through a pseudo terminal, so the line editor reads the input.
"$ZSH" -fc '
  zmodload zsh/zpty
  zpty -b shell "TERM=xterm-256color $1 -f -i"
  zpty -w shell "print hello-\$((6*7))"
  zpty -r -m shell out "*hello-42*" || exit 1
  zpty -d shell
' _ "$ZSH" || fail "interactive shell"
pass "interactive shell"

[ -f "$DIST/share/man/man1/zshall.1" ] || fail "man page zshall.1 missing"
pass "man pages"

if [ "$(uname -s)" = Linux ] && LC_ALL=C grep -a -q 'GLIBC_2\.' "$DIST/bin/zsh"; then
  max="$(LC_ALL=C grep -aoh 'GLIBC_2\.[0-9]*' "$DIST/bin/zsh" | sort -uV | tail -n 1)"
  [ "$(printf '%s\n' "$max" GLIBC_2.17 | sort -V | tail -n 1)" = GLIBC_2.17 ] \
    || fail "needs $max, newer than GLIBC_2.17"
  pass "glibc floor ($max)"
fi

echo "all smoke tests passed"
