# zsh-static

Portable, relocatable builds of the latest [zsh](https://www.zsh.org) with ncurses linked in
statically, built with [zig](https://ziglang.org) as the C toolchain. Forked from
[zsh-bin](https://github.com/romkatv/zsh-bin), whose builds stay at zsh 5.8.

- Linux glibc: only glibc is linked dynamically, and only symbols up to glibc 2.17, so the
  binaries run on anything from CentOS 7 onwards
- Linux musl (`--static`): fully static, no runtime dependencies at all (e.g. Alpine)
- macOS: only libSystem is dynamic (it ships with macOS, which has no fully static binaries)

All modules are linked into the binary, apart from `zsh/db/gdbm`, `zsh/pcre`, `zsh/cap`, and
`zsh/attr`, which need libraries that are not built. zsh finds its functions relative to its
binary, from `/proc/self/exe` on Linux and `proc_pidpath` on macOS, so the install works from any
directory, also through symlinks. The startup files in `/etc` of a system zsh are not read.

Common terminal descriptions (xterm, xterm-256color, screen, screen-256color, tmux, tmux-256color,
linux, vt100, vt220, rxvt, alacritty, kitty, foot, wezterm, ...) are compiled into ncurses, so the
line editor works even on systems without a terminfo database. The system database is still used
first, from `/etc/terminfo`, `/lib/terminfo`, `/usr/share/terminfo`, and `/usr/lib/terminfo`, or
from `$TERMINFO`, `$TERMINFO_DIRS`, and `~/.terminfo`.

## Prerequisites

- `zig`, GNU make (the `make` 3.81 of macOS is enough), `git`, `curl`, `xz`
- `autoconf` (the git tree of zsh ships no `configure` script)
- On macOS: Xcode Command Line Tools (SDK)

## Installation

Clone the repo with submodules (shallow, the history of the vendored projects is not needed):

```shell
git clone --recurse-submodules --shallow-submodules https://github.com/audivir/zsh-static
cd zsh-static
```

## Usage

```shell
./build.sh
```

This builds ncurses from `vendor/` as static libraries, then builds zsh against them. Output is
installed under `dist/`, a tree to copy to any prefix (e.g. `~/.local`):

- `dist/bin/zsh`: the binary
- `dist/share/zsh/<version>/functions`: the functions, including the completions
- `dist/share/man/man1`: the man pages, taken from the zsh release tarball, as building them needs
  yodl

Pass `--static` for the fully static musl build on Linux (output in `dist-static/`), `--clean` to
remove previous build output first, and `--jobs N` to control parallelism.

To run the smoke tests against the build:

```shell
./tests/run_smoke_tests.sh            # dist/
./tests/run_smoke_tests.sh --static   # dist-static/
```

## Releases

Publishing a GitHub release tagged with the zsh version (e.g. `v5.9.2`, matching the tag checked
out in `vendor/zsh`) builds and attaches `zsh-static-<platform>.tar.gz` for `macos-arm64`,
`linux-amd64`, `linux-arm64`, `linux-musl-amd64`, and `linux-musl-arm64`, together with the
sources they were built from (`zsh-static-sources.tar.gz`).

To update a vendored project, check out a new release tag in its submodule and commit it, e.g.
`git -C vendor/zsh fetch --depth 1 origin tag zsh-5.9.3 && git -C vendor/zsh checkout zsh-5.9.3`.

## Acknowledgments

This repository is forked from [zsh-bin](https://github.com/romkatv/zsh-bin) by Roman
Perepelitsa. It builds and vendors the following upstream projects, unmodified, as git submodules
under `vendor/`. Credit goes to their respective authors:

- [zsh](https://www.zsh.org) by Paul Falstad, the Zsh Development Group, and contributors
- [ncurses](https://invisible-island.net/ncurses/) by Thomas E. Dickey and the Free Software
  Foundation

## License

MIT for the code in this repository. See `NOTICE` for the licenses of the upstream projects and the
resulting binaries.
