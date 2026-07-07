# Makefile for the holyc monorepo. `make test` is the CI gate: unit tests for
# every module, then the black-box e2e harness. The harness has no
# code dependency on the compiler and invokes `hcc` from the PATH: the
# `install` target runs the platform's install script (install.sh, or
# install.ps1 on Windows), which builds hcc from source, installs it onto the
# PATH, and checks that LLVM is present.

ZIG ?= zig

# Release engineering. VERSION is the single source of truth in build.zig.zon;
# the tag is `v$(VERSION)`. HOST_ARCH/HOST_OSFRAG match the fragments the install
# scripts expect in an asset name: <bin>-<version>-<arch>-<osfrag>.tar.gz
# (arch ∈ amd64|arm64; osfrag ∈ linux|apple-darwin|windows). `make dist` builds
# only the host platform's assets — the other platforms come from a matching
# machine or CI running `make dist` there. Release engineering assumes a POSIX
# shell (macOS/Linux); on Windows, package via install.ps1 conventions.
MAIN_BRANCH ?= main
VERSION := $(shell sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)
HOST_ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
HOST_OSFRAG := $(shell uname -s | sed -e 's/Linux/linux/' -e 's/Darwin/apple-darwin/')
HCC_ASSET := hcc-v$(VERSION)-$(HOST_ARCH)-$(HOST_OSFRAG).tar.gz
LSP_ASSET := holyc-lsp-v$(VERSION)-$(HOST_ARCH)-$(HOST_OSFRAG).tar.gz

# Platform shims. GNU make sets OS=Windows_NT on Windows whatever the recipe
# shell is; the harness invocations below are quoted forward-slash paths,
# which both cmd and sh accept. Everything else ($(ZIG) build/test/fmt) is
# already portable.
ifeq ($(OS),Windows_NT)
EXE := .exe
INSTALL_CMD := powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Upgrade
CLEAN_CMD := powershell -NoProfile -Command "Remove-Item -Recurse -Force -ErrorAction Ignore zig-out, .zig-cache"
else
EXE :=
INSTALL_CMD := sh install.sh --upgrade
CLEAN_CMD := rm -rf zig-out .zig-cache
endif

.PHONY: default all test unit e2e bench install fmt fmt-check clean version dist tag

default: install

all:
	$(ZIG) build

test: unit e2e

unit:
	$(ZIG) build test

# Builds hcc from source and installs it onto the PATH (plus the LLVM check).
install:
	$(INSTALL_CMD)

# The harnesses assume hcc is installed on the PATH; `install` guarantees the
# binary under test is freshly built from this checkout.
e2e: all install
	"zig-out/bin/e2e$(EXE)" golden

# Times hcc-compiled fixtures against clang -O0..-O3 (compile and execution
# time; see bench/main.zig).
bench: all install
	"zig-out/bin/bench$(EXE)" benchmarks

fmt:
	$(ZIG) fmt build.zig hcc lsp e2e bench

fmt-check:
	$(ZIG) fmt --check build.zig hcc lsp e2e bench

clean:
	$(CLEAN_CMD)

# Prints the version the next tag would use (from build.zig.zon).
version:
	@echo "v$(VERSION)  ($(HOST_ARCH)-$(HOST_OSFRAG))"

# Builds this host's release assets into zig-out/release/, packaged and named
# exactly as the install scripts expect to download and extract:
#   hcc-v<ver>-<arch>-<osfrag>.tar.gz        → the `hcc` binary + the std/ tree
#   holyc-lsp-v<ver>-<arch>-<osfrag>.tar.gz  → the `holyc-lsp` binary
# plus SHA256SUMS over both. ReleaseSafe matches the from-source install. Binaries
# link libLLVM dynamically, so each is native to its build host — run `make dist`
# on every target platform (or in a CI matrix) and upload all of them to the tag.
dist:
	$(ZIG) build -Doptimize=ReleaseSafe
	@test -n "$(VERSION)" || { echo "dist: could not read .version from build.zig.zon"; exit 1; }
	rm -rf zig-out/release
	mkdir -p zig-out/release/stage
	cp zig-out/bin/hcc$(EXE) zig-out/release/stage/
	cp -R zig-out/std zig-out/release/stage/std
	tar -czf zig-out/release/$(HCC_ASSET) -C zig-out/release/stage hcc$(EXE) std
	rm -rf zig-out/release/stage
	mkdir -p zig-out/release/stage
	cp zig-out/bin/holyc-lsp$(EXE) zig-out/release/stage/
	tar -czf zig-out/release/$(LSP_ASSET) -C zig-out/release/stage holyc-lsp$(EXE)
	rm -rf zig-out/release/stage
	cd zig-out/release && { command -v sha256sum >/dev/null 2>&1 && sha256sum *.tar.gz || shasum -a 256 *.tar.gz; } > SHA256SUMS
	@printf 'dist: wrote zig-out/release/ for %s-%s:\n' "$(HOST_ARCH)" "$(HOST_OSFRAG)"
	@ls -1 zig-out/release

# Cuts the release: validates state, runs the fast gate, then creates and pushes
# the annotated tag v$(VERSION). Pushing the tag is the release trigger; upload
# the `make dist` assets from each platform to it (e.g. `gh release create
# v$(VERSION) zig-out/release/*`). Bump .version in build.zig.zon before tagging.
tag:
	@test -n "$(VERSION)" || { echo "tag: could not read .version from build.zig.zon"; exit 1; }
	@test -z "`git status --porcelain`" || { echo "tag: working tree is dirty — commit or stash first"; exit 1; }
	@test "`git rev-parse --abbrev-ref HEAD`" = "$(MAIN_BRANCH)" || { echo "tag: not on $(MAIN_BRANCH) (on `git rev-parse --abbrev-ref HEAD`)"; exit 1; }
	git fetch --quiet origin $(MAIN_BRANCH)
	@test "`git rev-parse HEAD`" = "`git rev-parse origin/$(MAIN_BRANCH)`" || { echo "tag: HEAD is not in sync with origin/$(MAIN_BRANCH) — push or pull first"; exit 1; }
	@git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null && { echo "tag: v$(VERSION) already exists — bump .version in build.zig.zon"; exit 1; } || true
	$(MAKE) fmt-check
	$(MAKE) unit
	git tag -a "v$(VERSION)" -m "holyc v$(VERSION)"
	git push origin "v$(VERSION)"
	@echo "tag: pushed v$(VERSION) — now upload each platform's \`make dist\` assets to the release"
