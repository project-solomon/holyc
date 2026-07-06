// Atomic.HC — atomics on an integer cell, and futex wait/wake. Compiler
// intrinsics: the prototypes put the names in scope for the type-checker and
// the compiler lowers each call to the matching atomic instruction (futexes
// to the host's wait/wake), so no bodies exist. Together with `lock { … }`
// (whose read-modify-write operations compile to atomic instructions), this
// is the synchronization vocabulary for Thread()-spawned threads. Part of the
// always-resident core (see Lib.HC).
#ifndef __PRELUDE_ATOMIC_HC
#define __PRELUDE_ATOMIC_HC

public I64 AtomicLoad(I64 *p);
public U0  AtomicStore(I64 *p, I64 v);
public I64 AtomicAdd(I64 *p, I64 delta); // returns the new value
public I64 AtomicSwap(I64 *p, I64 v);
public I64 AtomicCas(I64 *p, I64 expected, I64 desired);

public I64 FutexWait(I64 *addr, I64 expected);
public I64 FutexWake(I64 *addr, I64 n);
public I64 FutexWaitNs(I64 *addr, I64 expected, I64 ns);

#endif // __PRELUDE_ATOMIC_HC
