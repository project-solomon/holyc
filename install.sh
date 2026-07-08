#!/bin/sh
# install.sh — install hcc and/or holyc-lsp.
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

err() { printf 'install: error: %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<'USAGE_EOF'
install.sh — install hcc and/or holyc-lsp.

Builds from source with Zig when run from a repo checkout, else downloads a
tagged GitHub release. Installs to a bin dir on your PATH; for hcc it also checks
for LLVM 21. An existing install is kept unless --upgrade.

Usage:
  sh install.sh [options]
  curl -fsSL https://raw.githubusercontent.com/project-solomon/holyc/main/install.sh | sh -s -- [options]

Components (default: hcc):
  --lsp                also install holyc-lsp (the language server)
  --lsp-only           install only holyc-lsp (needs neither hcc nor LLVM)

Options:
  --uninstall          remove the selected component(s)
  --upgrade, -u        replace an existing install
  --build              build from source (needs a checkout and Zig)
  --download           download a release instead of building
  --version <tag>      release tag to download   (default: latest)
  --install-dir <dir>  install location          (default: a bin dir on your PATH)
  --llvm-prefix <dir>  LLVM 21 prefix            (default: auto-detected)
  --skip-llvm-check    install without LLVM 21
  --no-modify-path     print the PATH hint, don't edit your profile
  --dry-run, -n        show what would happen, make no changes
  --help, -h           show this help

Without --build/--download: source if run from a checkout with Zig, else a
release download.
USAGE_EOF
}

arg_err() { printf 'install: error: %s\n\n' "$1" >&2; usage >&2; exit 2; }

# ---- options ----
upgrade=0
with_lsp=0            # --lsp: also install the language server
lsp_only=0            # --lsp-only: just the language server
uninstall=0
dry_run=0
from_source=auto      # auto | 1 | 0
version=latest
install_dir=          # empty → derive per platform (default_install_dir)
llvm_prefix=          # empty → auto-detect (ensure_llvm)
skip_llvm_check=0
no_modify_path=0

while [ $# -gt 0 ]; do
	case "$1" in
		--lsp) with_lsp=1 ;;
		--lsp-only) lsp_only=1 ;;
		--uninstall) uninstall=1 ;;
		--upgrade | -u) upgrade=1 ;;
		--build | --from-source) from_source=1 ;; # --from-source: back-compat alias
		--download) from_source=0 ;;
		--skip-llvm-check) skip_llvm_check=1 ;;
		--no-modify-path) no_modify_path=1 ;;
		--dry-run | -n) dry_run=1 ;;
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

# ---- component set: hcc by default; --lsp adds holyc-lsp; --lsp-only swaps to
# just the server (holyc-lsp needs neither hcc nor LLVM). ----
if [ "$lsp_only" = 1 ]; then
	BINS="holyc-lsp"
elif [ "$with_lsp" = 1 ]; then
	BINS="hcc holyc-lsp"
else
	BINS="hcc"
fi
# Whether hcc is among the selected components (drives the LLVM check and stdlib).
wants_hcc() { case " $BINS " in *" hcc "*) return 0 ;; *) return 1 ;; esac; }

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

# The shell profile the PATH edit lands in (and is removed from on --uninstall).
profile_for_shell() {
	case "${SHELL:-}" in
		*/zsh) echo "$HOME/.zshrc" ;;
		*/bash) echo "$HOME/.bashrc" ;;
		*) echo "$HOME/.profile" ;;
	esac
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
	1) [ -n "$repo_root" ] || err "--build needs a holyc repo checkout (run install.sh from the repo root)" ;;
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
dir="${install_dir:-$(default_install_dir)}"
root="$(dirname "$dir")"

# ---- uninstall: remove the selected component(s), the stdlib (for hcc), any
# bundled DLLs, and our PATH line. Honors --dry-run. ----
if [ "$uninstall" = 1 ]; then
	did=0
	for bin in $BINS; do
		if [ -e "$dir/$bin" ]; then
			if [ "$dry_run" = 1 ]; then printf 'install: would remove %s\n' "$dir/$bin"
			else rm -f "$dir/$bin" && printf 'install: removed %s\n' "$dir/$bin"; fi
			did=1
		fi
	done
	if wants_hcc && [ -d "$root/std" ]; then
		if [ "$dry_run" = 1 ]; then printf 'install: would remove %s\n' "$root/std"
		else rm -rf "$root/std" && printf 'install: removed %s\n' "$root/std"; fi
		did=1
	fi
	profile="$(profile_for_shell)"
	path_line="export PATH=\"$dir:\$PATH\""
	if [ "$no_modify_path" != 1 ] && [ -f "$profile" ] && grep -Fqs "$path_line" "$profile"; then
		if [ "$dry_run" = 1 ]; then
			printf 'install: would remove the PATH entry from %s\n' "$profile"
		else
			tmpf=$(mktemp 2>/dev/null || mktemp -t hcc) &&
				grep -vF -e '# added by hcc install.sh' -e "$path_line" "$profile" >"$tmpf" &&
				cat "$tmpf" >"$profile" && rm -f "$tmpf"
			printf 'install: removed the PATH entry from %s\n' "$profile"
		fi
	fi
	[ "$did" = 1 ] || printf 'install: nothing to uninstall for %s in %s\n' "$BINS" "$dir"
	exit 0
fi

# ---- dry run: report the plan and stop before touching anything ----
if [ "$dry_run" = 1 ]; then
	printf 'install: dry run — no changes will be made\n'
	printf '  components:  %s\n' "$BINS"
	if [ "$from_source" = 1 ]; then
		printf '  mode:        build from source (%s)\n' "$repo_root"
	else
		printf '  mode:        download release %s\n' "$version"
	fi
	printf '  install dir: %s\n' "$dir"
	if wants_hcc; then printf '  stdlib:      %s\n' "$root/std"; fi
	case ":$PATH:" in
		*":$dir:"*) printf '  PATH:        already contains %s\n' "$dir" ;;
		*) if [ "$no_modify_path" = 1 ]; then printf '  PATH:        would print a hint for %s\n' "$dir"
		   else printf '  PATH:        would add %s to %s\n' "$dir" "$(profile_for_shell)"; fi ;;
	esac
	exit 0
fi

# ---- skip when already installed (unless --upgrade) ----
if [ "$upgrade" != 1 ]; then
	missing=0
	for bin in $BINS; do
		[ -e "$dir/$bin" ] || missing=1
	done
	# An hcc install also owns the stdlib at <root>/std; if the binary is present
	# but the stdlib isn't (e.g. upgrading from a pre-stdlib hcc), there is still
	# work to do.
	if wants_hcc && [ ! -d "$root/std" ]; then missing=1; fi
	if [ "$missing" = 0 ]; then
		printf 'install: %s already installed in %s — nothing to do (use --upgrade to replace)\n' "$BINS" "$dir"
		exit 0
	fi
fi

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t hcc)
trap 'rm -rf "$tmp"' EXIT INT TERM

# Only an hcc install needs LLVM; holyc-lsp never touches it.
if wants_hcc; then ensure_llvm; fi

if [ "$from_source" = 1 ]; then
	# ---- build from source for the host: per-artifact build steps, so an
	# LSP-only install never links (or requires) LLVM ----
	have zig || err "building from source needs Zig 0.16 (https://ziglang.org/download/); or pass --download to fetch a release"
	steps=""
	for bin in $BINS; do
		case "$bin" in
			hcc) steps="$steps hcc" ;;
			holyc-lsp) steps="$steps lsp" ;;
		esac
	done
	printf 'install: building %s from source (%s)\n' "$BINS" "$repo_root"
	# shellcheck disable=SC2086 # $steps is an intentional word list
	( cd "$repo_root" && zig build $steps -Doptimize=ReleaseSafe ${llvm_prefix:+-Dllvm-prefix="$llvm_prefix"} ) || err "zig build failed"
	for bin in $BINS; do
		cp "$repo_root/zig-out/bin/$bin" "$tmp/$bin" || err "zig build did not produce $bin"
	done
	# Stage the standard-library source tree beside the staged binary, so the
	# install step below places it at <root>/std.
	if wants_hcc; then cp -R "$repo_root/std" "$tmp/std" || err "could not stage the standard library"; fi
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

# ---- install the standard library into the toolchain tree (hcc only) ----
# hcc discovers it as HCC_ROOT/std relative to its own path — <root>/std, where
# <root> is the parent of the bin dir. In --download mode this expects the
# release tarball to carry a top-level std/ dir; older tarballs without it simply
# skip the stdlib.
if wants_hcc && [ -d "$tmp/std" ]; then
	std_dir="$root/std"
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
			profile="$(profile_for_shell)"
			if grep -Fqs "$path_line" "$profile"; then
				printf 'install: %s already adds %s to PATH (restart your shell to pick it up)\n' "$profile" "$dir"
			else
				printf '\n# added by hcc install.sh\n%s\n' "$path_line" >>"$profile" ||
					err "cannot write to $profile (add to your PATH manually: $path_line)"
				printf 'install: added %s to PATH in %s (restart your shell to pick it up)\n' "$dir" "$profile"
			fi
		fi ;;
esac
if wants_hcc; then
	printf '\nRun: hcc --help\n'
fi
if ! wants_hcc || [ "$with_lsp" = 1 ]; then
	printf '\nholyc-lsp speaks LSP over stdio — point your editor at it\n'
fi
