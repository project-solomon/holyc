# Makefile for the holyc monorepo. `make test` is the CI gate: unit tests for
# every module, then the black-box e2e harness. The harness has no
# code dependency on the compiler and invokes `hcc` from the PATH: the
# `install` target runs the platform's install script (install.sh, or
# install.ps1 on Windows), which builds hcc from source, installs it onto the
# PATH, and checks that LLVM is present.

ZIG ?= zig

# VERSION is read from build.zig.zon. Releases are cut by the `release` GitHub
# Action (tag v<version>, build the platform matrix, upload assets); there is no
# local dist/tag target.
VERSION := $(shell sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)

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

.PHONY: default all test unit e2e bench install fmt fmt-check clean version

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

# Prints the version from build.zig.zon (the `release` workflow tags v<version>).
version:
	@echo "v$(VERSION)"
