#!/bin/sh
# install.sh — install the hcc HolyC compiler.
#
# By default it downloads a tagged GitHub release asset. When run from a
# checkout of the holyc repo (e.g. `sh install.sh` from the repo root) and Zig
# is available, it builds hcc from source for your host instead. It verifies
# LLVM 21 is present (hcc links libLLVM dynamically) and, if the install
# directory is not already on your PATH, appends an export line to your shell
# profile.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/project-solomon/holyc/main/install.sh | sh
#   sh install.sh            # from a repo checkout → builds from source
#   sh install.sh --lsp      # install ONLY the holyc-lsp language server
#   sh install.sh --upgrade  # replace an existing installation
#
# --lsp installs the language server INSTEAD of the compiler: holyc-lsp is
# driven by the front end alone, so it needs neither hcc nor LLVM (the LLVM
# check is skipped). Run the script once per binary to get both.
#
# An existing installation is left alone unless --upgrade (or HCC_UPGRADE=1,
# for curl-pipe use) is given. If the install directory is missing from PATH,
# the line to add it is appended to your shell profile (~/.zshrc, ~/.bashrc,
# or ~/.profile); set HCC_NO_MODIFY_PATH=1 to only print the hint instead.
#
# Environment overrides (set before the pipe, e.g. `... | HCC_VERSION=v0.1.0 sh`):
#   HCC_VERSION       release tag to install            (default: latest)
#   HCC_INSTALL_DIR   directory to install the binary
#                     (default: derived per platform — root: /usr/local/bin;
#                     else a user bin dir already on PATH (~/.local/bin, ~/bin);
#                     else a writable system bin dir on PATH (/opt/homebrew/bin,
#                     /usr/local/bin — the Homebrew dirs on macOS); else
#                     ~/.local/bin, wired into the shell profile)
#   HCC_FROM_SOURCE   1 = build from source, 0 = download a release
#                     (default: auto — source iff run from a repo checkout with Zig)
#   HCC_UPGRADE       1 = replace an existing installation (same as --upgrade)
#   HCC_LSP           1 = install only holyc-lsp (same as --lsp)
#   HCC_NO_MODIFY_PATH  1 = never edit shell profiles; print the PATH hint only
#   HCC_LLVM_PREFIX   LLVM installation prefix (default: auto-detected)
#   HCC_SKIP_LLVM_CHECK  1 = install even if LLVM 21 is not found
#
# Downloads auto-detect the OS (Linux/macOS) and architecture and fetch the
# matching release asset `hcc-<version>-<arch>-<os>.tar.gz` (e.g.
# hcc-v0.1.0-amd64-apple-darwin.tar.gz) — the names release packaging produces.
# For Windows, use install.ps1.
set -eu

REPO="project-solomon/holyc"
BIN="hcc"

upgrade="${HCC_UPGRADE:-0}"
with_lsp="${HCC_LSP:-0}"
for arg in "$@"; do
	case "$arg" in
		--upgrade | -u) upgrade=1 ;;
		--lsp) with_lsp=1 ;;
		*) printf 'install: error: unknown argument %s\n' "$arg" >&2; exit 2 ;;
	esac
done

# hcc by default; --lsp swaps it for the language server (holyc-lsp needs
# neither hcc nor LLVM). Both follow the same skip/upgrade rules.
if [ "$with_lsp" = 1 ]; then BINS="holyc-lsp"; else BINS="$BIN"; fi

err() { printf 'install: error: %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

http_get() { # url -> stdout
	if have curl; then curl -fsSL "$1"
	elif have wget; then wget -qO- "$1"
	else err "need curl or wget"; fi
}
http_download() { # url file
	if have curl; then curl -fsSL "$1" -o "$2"
	elif have wget; then wget -qO "$2" "$1"
	else err "need curl or wget"; fi
}

# ---- LLVM check: hcc links libLLVM dynamically, so LLVM 21 must exist both to
# build from source and to RUN a downloaded release binary. Sets llvm_prefix
# (may stay empty when the check is skipped).
llvm_prefix="${HCC_LLVM_PREFIX:-}"
ensure_llvm() {
	[ "${HCC_SKIP_LLVM_CHECK:-0}" = 1 ] && return 0
	if [ -z "$llvm_prefix" ]; then
		for p in /opt/homebrew/opt/llvm@21 /usr/local/opt/llvm@21 /usr/lib/llvm-21; do
			if [ -d "$p/lib" ]; then llvm_prefix="$p"; break; fi
		done
	fi
	if [ -z "$llvm_prefix" ] && have llvm-config; then
		llvm_prefix=$(llvm-config --prefix 2>/dev/null || true)
	fi
	if [ -n "$llvm_prefix" ]; then
		if [ -e "$llvm_prefix/lib/libLLVM.dylib" ] || ls "$llvm_prefix"/lib/libLLVM*.so* >/dev/null 2>&1; then
			return 0
		fi
	fi
	err "hcc links LLVM dynamically and needs LLVM 21 at runtime, but none was found.
       Install it (macOS: brew install llvm@21; Debian/Ubuntu: apt install llvm-21),
       or point at an install with HCC_LLVM_PREFIX. Set HCC_SKIP_LLVM_CHECK=1 to install anyway."
}

# ---- locate the repo, but only when run as a local file (not piped via curl) ----
# When piped (`curl ... | sh`), $0 is the shell, not this script, so repo_root
# stays empty and we fall through to the release download.
repo_root=""
if [ -f "$0" ]; then
	self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || self_dir=""
	[ -n "$self_dir" ] && [ -f "$self_dir/build.zig" ] && repo_root="$self_dir"
fi

# ---- decide download vs. build-from-source ----
from_source="${HCC_FROM_SOURCE:-auto}"
case "$from_source" in
	1 | true | yes | on)
		[ -n "$repo_root" ] || err "HCC_FROM_SOURCE is set, but this isn't a holyc repo checkout (run install.sh from the repo root)"
		from_source=1 ;;
	0 | false | no | off)
		from_source=0 ;;
	auto)
		if [ -n "$repo_root" ] && have zig; then from_source=1; else from_source=0; fi ;;
	*) err "invalid HCC_FROM_SOURCE '$from_source' (use 1 or 0)" ;;
esac

# ---- install dir: HCC_INSTALL_DIR wins; otherwise derive it per platform ----
# Preference order: a system dir when root; a user bin dir already on this
# shell's PATH (no profile edit needed); a writable system bin dir already on
# the PATH (Homebrew's /opt/homebrew/bin on ARM macs, /usr/local/bin on Intel
# — macOS puts nothing user-writable on the default PATH otherwise); finally
# ~/.local/bin, which the PATH machinery below wires into the shell profile.
default_install_dir() {
	if [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then
		echo /usr/local/bin
		return
	fi
	for d in "$HOME/.local/bin" "$HOME/bin"; do
		case ":$PATH:" in *":$d:"*) echo "$d"; return ;; esac
	done
	for d in /opt/homebrew/bin /usr/local/bin; do
		if [ -d "$d" ] && [ -w "$d" ]; then
			case ":$PATH:" in *":$d:"*) echo "$d"; return ;; esac
		fi
	done
	echo "$HOME/.local/bin"
}

# ---- skip when already installed (unless --upgrade) ----
dir="${HCC_INSTALL_DIR:-$(default_install_dir)}"
if [ "$upgrade" != 1 ]; then
	missing=0
	for bin in $BINS; do
		[ -e "$dir/$bin" ] || missing=1
	done
	if [ "$missing" = 0 ]; then
		printf 'install: %s already installed in %s — nothing to do (use --upgrade to replace)\n' "$BINS" "$dir"
		exit 0
	fi
fi

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t hcc)
trap 'rm -rf "$tmp"' EXIT INT TERM

# holyc-lsp never touches LLVM; only an hcc install needs the check.
[ "$with_lsp" = 1 ] || ensure_llvm

if [ "$from_source" = 1 ]; then
	# ---- build from source for the host: per-artifact build steps, so an
	# LSP-only install never links (or requires) LLVM ----
	have zig || err "building from source needs Zig 0.16 (https://ziglang.org/download/); or set HCC_FROM_SOURCE=0 to download a release"
	if [ "$with_lsp" = 1 ]; then build_step=lsp; else build_step=hcc; fi
	printf 'install: building %s from source (%s)\n' "$BINS" "$repo_root"
	( cd "$repo_root" && zig build "$build_step" -Doptimize=ReleaseSafe ${llvm_prefix:+-Dllvm-prefix="$llvm_prefix"} ) || err "zig build failed"
	for bin in $BINS; do
		cp "$repo_root/zig-out/bin/$bin" "$tmp/$bin" || err "zig build did not produce $bin"
	done
else
	# ---- detect platform (os/arch fragments match the release asset names) ----
	os=$(uname -s)
	case "$os" in
		Linux) os=linux; osfrag=linux ;;
		Darwin) os=darwin; osfrag=apple-darwin ;;
		*) err "unsupported OS '$os' (use install.ps1 on Windows)" ;;
	esac

	arch=$(uname -m)
	case "$arch" in
		x86_64 | amd64) arch=amd64 ;;
		aarch64 | arm64) arch=arm64 ;;
		*) err "unsupported architecture '$arch'" ;;
	esac

	# ---- resolve version (latest release tag unless pinned) ----
	version="${HCC_VERSION:-latest}"
	if [ "$version" = latest ]; then
		version=$(http_get "https://api.github.com/repos/$REPO/releases/latest" |
			grep -m1 '"tag_name"' |
			sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
		[ -n "$version" ] || err "could not determine the latest release (set HCC_VERSION to a tag)"
	fi

	# Everything in BINS was explicitly requested, so a missing asset is fatal.
	for bin in $BINS; do
		asset="${bin}-${version}-${arch}-${osfrag}.tar.gz"
		url="https://github.com/$REPO/releases/download/$version/$asset"
		printf 'install: downloading %s %s (%s/%s)\n' "$bin" "$version" "$os" "$arch"
		http_download "$url" "$tmp/$asset" || err "download failed: $url"
		tar -xzf "$tmp/$asset" -C "$tmp" || err "failed to extract $asset"
		[ -f "$tmp/$bin" ] || err "the archive did not contain a '$bin' binary"
	done
fi

# ---- install ----
mkdir -p "$dir" || err "cannot create $dir"
for bin in $BINS; do
	[ -f "$tmp/$bin" ] || continue
	if [ -e "$dir/$bin" ] && [ "$upgrade" != 1 ]; then
		printf 'install: %s already exists in %s — skipping (use --upgrade to replace)\n' "$bin" "$dir"
		continue
	fi
	if ! install -m 0755 "$tmp/$bin" "$dir/$bin" 2>/dev/null; then
		cp "$tmp/$bin" "$dir/$bin" && chmod 0755 "$dir/$bin" ||
			err "cannot write to $dir (set HCC_INSTALL_DIR, or re-run with sudo)"
	fi
	printf 'install: installed %s to %s\n' "$bin" "$dir/$bin"
done

# ---- ensure the install dir is on the PATH (mirrors install.ps1) ----
path_line="export PATH=\"$dir:\$PATH\""
case ":$PATH:" in
	*":$dir:"*) ;;
	*)
		if [ "${HCC_NO_MODIFY_PATH:-0}" = 1 ]; then
			printf '\nAdd it to your PATH:\n  %s\n' "$path_line"
		else
			case "${SHELL:-}" in
				*/zsh) profile="$HOME/.zshrc" ;;
				*/bash) profile="$HOME/.bashrc" ;;
				*) profile="$HOME/.profile" ;;
			esac
			if grep -Fqs "$path_line" "$profile"; then
				printf 'install: %s already adds %s to PATH (restart your shell to pick it up)\n' "$profile" "$dir"
			else
				printf '\n# added by hcc install.sh\n%s\n' "$path_line" >>"$profile" ||
					err "cannot write to $profile (add to your PATH manually: $path_line)"
				printf 'install: added %s to PATH in %s (restart your shell to pick it up)\n' "$dir" "$profile"
			fi
		fi ;;
esac
if [ "$with_lsp" = 1 ]; then
	printf '\nholyc-lsp speaks LSP over stdio — point your editor at it\n'
else
	printf '\nRun: %s --help\n' "$BIN"
fi
