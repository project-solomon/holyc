// Lib.HC — the always-resident HolyC prelude, injected into every program so
// its definitions are in scope without an #include.
//
// This is the DIALECT CORE, not a standard library: the pieces the language
// itself depends on — the exception context (CTask), reflection (KClass), the
// print engine behind implicit print (StrPrint), the task heap (Mem), process
// exit, host file/socket I/O, and the concurrency vocabulary (POSIX threads, atomics, and the
// `lock { … }` block they give meaning to). Everything else is the C standard
// library, reachable with an ordinary `extern` declaration (libc is always
// linked).
//
// It is nothing but the boot order: an authored, explicit #include list.
// Nothing is auto-pulled on demand — every program gets all of it, and unused
// code is dropped at emit time (whole-program DCE), not by selective loading.
// The user never #includes any of this.
//
// Order matters: HolyC is single-pass, so a name must be declared before use,
// and KConfig's macros must come first.
#ifndef __PRELUDE_LIB_HC
#define __PRELUDE_LIB_HC

#include "KConfig.HC"        // NULL / TRUE / FALSE
#include "CTask.HC"          // CTask (the task / exception context)
#include "MAllocFree.HC"     // MAlloc Free MSize HeapExtend, ReAlloc CAlloc
#include "Time.HC"           // UnixNS NanoNS CpuNS Sleep
#include "StrPrint.HC"       // StdWrite, the %-formatter, Print / FPrint
#include "KClass.HC"         // CHashClass/CMemberLst, Class(), ClassRep — reflection
#include "Proc.HC"           // Exit System Getpid …
#include "File.HC"           // Open Read Write Close, fs mutation, cwd
#include "Net.HC"            // Socket Connect
#include "Thread.HC"         // Thread Join … Gettid (POSIX threads)
#include "Atomic.HC"         // atomics + futex; pairs with lock { … }

#endif // __PRELUDE_LIB_HC
