// CTask.HC — the task / exception context, TempleOS's CTask (reachable as
// Fs): the try/throw/catch machinery and the backends read its
// fields. Part of the always-resident prelude (see Lib.HC).
#ifndef __PRELUDE_CTASK_HC
#define __PRELUDE_CTASK_HC

public class CTask {
  U8  *self;         // self-pointer (the TLS slot stores &CTask)
  I64  except_ch;    // the value passed to throw, readable inside catch
  I64  catch_except; // 1 while handling an exception, else 0
  U8  *exc_top;      // top of this thread's try/catch handler-frame chain
};

#endif // __PRELUDE_CTASK_HC
