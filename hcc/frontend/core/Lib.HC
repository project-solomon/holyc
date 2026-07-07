// Lib.HC — the always-resident HolyC prelude, injected into every program so
// its definitions are in scope without an #include.
//
// This is the DIALECT CORE, not a standard library: only the pieces the
// language itself emits calls to or whose syntax depends on them — the
// predefined constants (NULL/TRUE/FALSE), the exception context (CTask) behind
// try/catch/throw, the print engine behind implicit print (StrPrint), and
// reflection (KClass, which the compiler synthesizes). Everything the hosted
// runtime offers — the heap (MAlloc), process control (Exit), file/socket I/O,
// clocks, and threads/atomics — is the standard library, opt-in with
// `#include <Mem.HC>`, `<File.HC>`, `<Net.HC>`, `<Time.HC>`, `<Sync.HC>`,
// `<Proc.HC>` (and further out, the C library via `extern`, libc always
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
#include "StrPrint.HC"       // StdWrite, the %-formatter, Print / FPrint
#include "KClass.HC"         // CHashClass/CMemberLst, Class(), ClassRep — reflection

#endif // __PRELUDE_LIB_HC
