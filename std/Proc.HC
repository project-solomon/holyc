// Proc.HC — host process control and identity. `#include <Proc.HC>`.
//
// Compiler intrinsics: the prototypes put the names in scope for the
// type-checker and the compiler lowers each call directly to the libc
// equivalent, so no bodies exist. A host service, not part of the dialect core
// — a program that terminates by returning from its top level needs none of
// this; Exit is only for an explicit exit code or to run AtExit handlers.
#ifndef __STD_PROC_HC
#define __STD_PROC_HC

public U0  Exit(I64 code);
public U0  ExitRaw(I64 code); // exit without running AtExit handlers (C `_Exit`)
public I64 System(U8 *cmd);
public I64 Getpid();
public I64 Getppid();
public I64 Getuid();
public I64 Getgid();

#endif // __STD_PROC_HC
