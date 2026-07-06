// KConfig.HC — compiler-predefined constants. Included first because macros must
// be in scope before anything is parsed (they are resolved by the preprocessor, so
// they cannot be supplied any later).
//
// The target macros below are NOT defined here; they are seeded separately by
// the preprocessor (see targetMacros in hcc/frontend/Preprocessor.zig), keyed
// off the active target triple. Each expands to 1:
//   __HCC__                        always defined
//   __amd64__                      arch is amd64
//   __arm64__                      arch is arm64
//   __riscv64__                    arch is riscv64
//   __ppc64le__                    arch is ppc64le
//   __s390x__                      arch is s390x
//   __APPLE__, __MACH__, __unix__  OS is darwin
//   __linux__, __unix__            OS is linux
//   _WIN32, _WIN64                 OS is windows
#ifndef __PRELUDE_KCONFIG_HC
#define __PRELUDE_KCONFIG_HC

#define NULL  0
#define TRUE  1
#define FALSE 0

#endif // __PRELUDE_KCONFIG_HC
