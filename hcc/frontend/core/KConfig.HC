// KConfig.HC — compiler-predefined constants and the standard target macros.
// Injected first (see core.zig boot order) because macros must be in scope
// before anything is parsed: the preprocessor resolves them, so they can't be
// supplied later.
//
// The compiler seeds one internal flag per arch/OS from the target triple (see
// targetMacros in hcc/frontend/Preprocessor.zig): __HCC_ARCH_*__ and
// __HCC_OS_*__. This file derives the public spellings from them, so `#ifdef
// __APPLE__` works and an editor can jump to the definition here. __HCC__
// (always defined) is seeded directly by the compiler.
#ifndef __CORE_KCONFIG_HC
#define __CORE_KCONFIG_HC

#define NULL  0
#define TRUE  1
#define FALSE 0

// Architecture (exactly one is active).
#ifdef __HCC_ARCH_AMD64__
#define __amd64__ 1
#endif
#ifdef __HCC_ARCH_ARM64__
#define __arm64__ 1
#endif
#ifdef __HCC_ARCH_RISCV64__
#define __riscv64__ 1
#endif
#ifdef __HCC_ARCH_PPC64LE__
#define __ppc64le__ 1
#endif
#ifdef __HCC_ARCH_S390X__
#define __s390x__ 1
#endif

// Operating system (exactly one is active).
#ifdef __HCC_OS_DARWIN__
#define __APPLE__ 1
#define __MACH__  1
#define __unix__  1
#endif
#ifdef __HCC_OS_LINUX__
#define __linux__ 1
#define __unix__  1
#endif
#ifdef __HCC_OS_WINDOWS__
#define _WIN32 1
#define _WIN64 1
#endif

#endif // __CORE_KCONFIG_HC
