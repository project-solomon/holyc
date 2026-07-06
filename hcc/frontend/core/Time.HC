// Time.HC — clocks, in nanoseconds. Compiler intrinsics: the prototypes put
// the names in scope for the type-checker and each call lowers to
// clock_gettime/nanosleep, so no bodies exist. Part of the always-resident
// core (see Lib.HC).
#ifndef __PRELUDE_TIME_HC
#define __PRELUDE_TIME_HC

public I64 UnixNS();   // wall-clock since 1970 (CLOCK_REALTIME)
public I64 NanoNS();   // monotonic from an arbitrary origin (CLOCK_MONOTONIC)
public I64 CpuNS();    // process CPU time (CLOCK_PROCESS_CPUTIME_ID)
public U0  Sleep(I64 ns);

#endif // __PRELUDE_TIME_HC
