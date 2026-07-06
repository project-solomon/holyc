// Thread.HC — POSIX host threads (the entry point is `I64 fn(I64 arg)`).
// Compiler intrinsics: the prototypes put the names in scope for the
// type-checker and the compiler lowers each call onto pthreads, so no bodies
// exist. Part of the always-resident core (see Lib.HC).
#ifndef __PRELUDE_THREAD_HC
#define __PRELUDE_THREAD_HC

public I64 Thread(I64 (*fn)(I64), I64 arg); // spawn fn(arg); returns a Join handle, or -1
public I64 Join(I64 handle);
public I64 ThreadYield();
public U0  ThreadExit(I64 ret);
public I64 ThreadDetach(I64 handle);
public I64 Gettid();

#endif // __PRELUDE_THREAD_HC
