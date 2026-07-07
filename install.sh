#!/bin/sh
# install.sh — install hcc (or holyc-lsp).
#
# Builds from source with Zig when run from a repo checkout, else downloads a
# tagged GitHub release. Installs to a bin dir on your PATH, checks for LLVM 21
# (hcc links libLLVM dynamically), and adds the bin dir to your shell profile if
# it is missing from PATH.
#
#   sh install.sh [options]
#   curl -fsSL <url>/install.sh | sh
#   curl -fsSL <url>/install.sh | sh -s -- --lsp   # options through a pipe: -s --
#
# Release assets are <bin>-<version>-<arch>-<os>.tar.gz. Windows: use install.ps1.
# Run `sh install.sh --help` for options.
set -eu

REPO="project-solomon/holyc"
BIN="hcc"

err() { printf 'install: error: %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<'USAGE_EOF'
install.sh — install hcc (or holyc-lsp).

Builds from source with Zig when run from a repo checkout, else downloads a
tagged GitHub release. Installs to a bin dir on your PATH; for hcc it also checks
for LLVM 21. An existing install is kept unless --upgrade.

Usage:
  sh install.sh [options]
  curl -fsSL https://raw.githubusercontent.com/project-solomon/holyc/main/install.sh | sh -s -- [options]

Options:
  --lsp                install holyc-lsp instead of hcc
  --upgrade, -u        replace an existing install
  --from-source        build from source (needs a checkout and Zig)
  --download           download a release instead of building
  --version <tag>      release tag to download   (default: latest)
  --install-dir <dir>  install location          (default: a bin dir on your PATH)
  --llvm-prefix <dir>  LLVM 21 prefix            (default: auto-detected)
  --skip-llvm-check    install without LLVM 21
  --no-modify-path     print the PATH hint, don't edit your profile
  --help, -h           show this help

Without --from-source/--download: source if run from a checkout with Zig, else
a release download.
USAGE_EOF
}

arg_err() { printf 'install: error: %s\n\n' "$1" >&2; usage >&2; exit 2; }

# ---- options ----
upgrade=0
with_lsp=0
from_source=auto      # auto | 1 | 0
version=latest
install_dir=          # empty → derive per platform (default_install_dir)
llvm_prefix=          # empty → auto-detect (ensure_llvm)
skip_llvm_check=0
no_modify_path=0

while [ $# -gt 0 ]; do
	case "$1" in
		--lsp) with_lsp=1 ;;
		--upgrade | -u) upgrade=1 ;;
		--from-source) from_source=1 ;;
		--download) from_source=0 ;;
		--skip-llvm-check) skip_llvm_check=1 ;;
		--no-modify-path) no_modify_path=1 ;;
		--version) [ $# -ge 2 ] || arg_err "--version needs a value"; version="$2"; shift ;;
		--version=*) version="${1#*=}" ;;
		--install-dir) [ $# -ge 2 ] || arg_err "--install-dir needs a value"; install_dir="$2"; shift ;;
		--install-dir=*) install_dir="${1#*=}" ;;
		--llvm-prefix) [ $# -ge 2 ] || arg_err "--llvm-prefix needs a value"; llvm_prefix="$2"; shift ;;
		--llvm-prefix=*) llvm_prefix="${1#*=}" ;;
		--help | -h) usage; exit 0 ;;
		*) arg_err "unknown argument $1" ;;
	esac
	shift
done

# hcc by default; --lsp swaps it for the language server (holyc-lsp needs
# neither hcc nor LLVM). Both follow the same skip/upgrade rules.
if [ "$with_lsp" = 1 ]; then BINS="holyc-lsp"; else BINS="$BIN"; fi

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
ensure_llvm() {
	[ "$skip_llvm_check" = 1 ] && return 0
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
       point at an install with --llvm-prefix <dir>, or pass --skip-llvm-check to install anyway."
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
case "$from_source" in
	1) [ -n "$repo_root" ] || err "--from-source needs a holyc repo checkout (run install.sh from the repo root)" ;;
	0) ;;
	auto) if [ -n "$repo_root" ] && have zig; then from_source=1; else from_source=0; fi ;;
esac

# ---- install dir: --install-dir wins; otherwise a dedicated toolchain tree ----
# holyc installs as a self-contained tree like Go's GOROOT: <root>/bin/hcc,
# <root>/std (the stdlib), and <root>/pkg (third-party packages), so hcc finds
# HCC_ROOT as the parent of its own bin dir. The default root is ~/hcc (or
# /usr/local/hcc when root); its bin/ is wired onto PATH by the machinery below.
# --install-dir overrides the *bin* dir; the tree is derived from its parent.
default_install_dir() {
	if [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then
		echo /usr/local/hcc/bin
	else
		echo "$HOME/hcc/bin"
	fi
}

# ---- skip when already installed (unless --upgrade) ----
dir="${install_dir:-$(default_install_dir)}"
if [ "$upgrade" != 1 ]; then
	missing=0
	for bin in $BINS; do
		[ -e "$dir/$bin" ] || missing=1
	done
	# An hcc install also owns the stdlib at <root>/std; if the binary
	# is present but the stdlib isn't (e.g. upgrading from a pre-stdlib hcc),
	# there is still work to do.
	[ "$with_lsp" = 1 ] || [ -d "$(dirname "$dir")/std" ] || missing=1
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
	have zig || err "building from source needs Zig 0.16 (https://ziglang.org/download/); or pass --download to fetch a release"
	if [ "$with_lsp" = 1 ]; then build_step=lsp; else build_step=hcc; fi
	printf 'install: building %s from source (%s)\n' "$BINS" "$repo_root"
	( cd "$repo_root" && zig build "$build_step" -Doptimize=ReleaseSafe ${llvm_prefix:+-Dllvm-prefix="$llvm_prefix"} ) || err "zig build failed"
	for bin in $BINS; do
		cp "$repo_root/zig-out/bin/$bin" "$tmp/$bin" || err "zig build did not produce $bin"
	done
	# Stage the standard-library source tree beside the staged binary, so the
	# install step below places it at <root>/std.
	[ "$with_lsp" = 1 ] || cp -R "$repo_root/std" "$tmp/std" || err "could not stage the standard library"
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

	# ---- resolve version (latest release tag unless pinned with --version) ----
	if [ "$version" = latest ]; then
		version=$(http_get "https://api.github.com/repos/$REPO/releases/latest" |
			grep -m1 '"tag_name"' |
			sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
		[ -n "$version" ] || err "could not determine the latest release (pass --version <tag>)"
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
			err "cannot write to $dir (pass --install-dir <dir>, or re-run with sudo)"
	fi
	printf 'install: installed %s to %s\n' "$bin" "$dir/$bin"
done

# ---- install the standard library into the toolchain tree (not for --lsp) ----
# hcc discovers it as HCC_ROOT/std relative to its own path — <root>/std, where
# <root> is the parent of the bin dir. In --download mode this expects the
# release tarball to carry a top-level std/ dir (a new asset convention); older
# tarballs without it simply skip the stdlib.
if [ "$with_lsp" != 1 ] && [ -d "$tmp/std" ]; then
	std_dir="$(dirname "$dir")/std"
	mkdir -p "$std_dir" || err "cannot create $std_dir"
	rm -f "$std_dir"/*.HC 2>/dev/null || true
	for f in "$tmp/std"/*.HC; do
		[ -f "$f" ] || continue
		install -m 0644 "$f" "$std_dir/" 2>/dev/null || cp "$f" "$std_dir/" ||
			err "cannot write the standard library to $std_dir (pass --install-dir <dir>, or re-run with sudo)"
	done
	printf 'install: installed the standard library to %s\n' "$std_dir"
fi

# ---- ensure the install dir is on the PATH (mirrors install.ps1) ----
path_line="export PATH=\"$dir:\$PATH\""
case ":$PATH:" in
	*":$dir:"*) ;;
	*)
		if [ "$no_modify_path" = 1 ]; then
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
