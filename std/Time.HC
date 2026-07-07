// Time.HC — clocks, in nanoseconds. `#include <Time.HC>`.
//
// Compiler intrinsics: the prototypes put the names in scope for the
// type-checker and each call lowers to clock_gettime/nanosleep, so no bodies
// exist. A host service, not part of the dialect core.
#ifndef __STD_TIME_HC
#define __STD_TIME_HC

public I64 UnixNS();   // wall-clock since 1970 (CLOCK_REALTIME)
public I64 NanoNS();   // monotonic from an arbitrary origin (CLOCK_MONOTONIC)
public I64 CpuNS();    // process CPU time (CLOCK_PROCESS_CPUTIME_ID)
public U0  Sleep(I64 ns);

#endif // __STD_TIME_HC
