// Sync.HC — host concurrency: POSIX threads plus the atomics and futexes that
// coordinate them. `#include <Sync.HC>`.
//
// Compiler intrinsics: the prototypes put the names in scope for the
// type-checker and the compiler lowers each call onto pthreads / the matching
// atomic instruction (futexes to the host's wait/wake), so no bodies exist.
// Together with the `lock { … }` block (a language construct whose
// read-modify-write operations compile to atomic instructions on their own,
// needing nothing from this file), this is the synchronization vocabulary for
// Thread()-spawned threads. A host service, not part of the dialect core.
#ifndef __STD_SYNC_HC
#define __STD_SYNC_HC

// ---- POSIX threads (the entry point is `I64 fn(I64 arg)`) ----
public I64 Thread(I64 (*fn)(I64), I64 arg); // spawn fn(arg); returns a Join handle, or -1
public I64 Join(I64 handle);
public I64 ThreadYield();
public U0  ThreadExit(I64 ret);
public I64 ThreadDetach(I64 handle);
public I64 Gettid();

// ---- atomics on an integer cell, and futex wait/wake ----
public I64 AtomicLoad(I64 *p);
public U0  AtomicStore(I64 *p, I64 v);
public I64 AtomicAdd(I64 *p, I64 delta); // returns the new value
public I64 AtomicSwap(I64 *p, I64 v);
public I64 AtomicCas(I64 *p, I64 expected, I64 desired);

public I64 FutexWait(I64 *addr, I64 expected);
public I64 FutexWake(I64 *addr, I64 n);
public I64 FutexWaitNs(I64 *addr, I64 expected, I64 ns);

#endif // __STD_SYNC_HC
