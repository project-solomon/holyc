// Proc.HC — host process control and identity. Compiler intrinsics: the
// prototypes put the names in scope for the type-checker and the compiler
// lowers each call directly to the libc equivalent, so no bodies exist. Part
// of the always-resident core (see Lib.HC).
#ifndef __PRELUDE_PROC_HC
#define __PRELUDE_PROC_HC

public U0  Exit(I64 code);
public U0  ExitRaw(I64 code); // exit without running AtExit handlers (C `_Exit`)
public I64 System(U8 *cmd);
public I64 Getpid();
public I64 Getppid();
public I64 Getuid();
public I64 Getgid();

#endif // __PRELUDE_PROC_HC
