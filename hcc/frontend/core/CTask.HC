// CTask.HC — the task / exception context, TempleOS's CTask (reachable as
// Fs). The try/throw/catch machinery and the backends read its fields. Part
// of the always-resident core (see core.zig).
#ifndef __CORE_CTASK_HC
#define __CORE_CTASK_HC

public class CTask {
  U8  *self;         // self-pointer (the TLS slot stores &CTask)
  I64  except_ch;    // the value passed to throw, readable inside catch
  I64  catch_except; // 1 while handling an exception, else 0
  U8  *exc_top;      // top of this thread's try/catch handler-frame chain
};

#endif // __CORE_CTASK_HC
