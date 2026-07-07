// POSIX threads + lock + atomics: 8 threads each do 10000 lock-guarded
// increments and 10000 AtomicAdds. Any lost update means lock{} or the
// atomics are broken, so the totals are deterministic.
#include <Sync.HC> // Thread/Join + AtomicAdd
I64 counter = 0;
I64 acount = 0;

I64 Worker(I64 n)
{
  I64 i;
  for (i = 0; i < n; i++) {
    lock {
      counter++;
    }
    AtomicAdd(&acount, 1);
  }
  return n;
}

I64 handles[8];
I64 t;
for (t = 0; t < 8; t++)
  handles[t] = Thread(&Worker, 10000);
I64 sum = 0;
for (t = 0; t < 8; t++)
  sum += Join(handles[t]);
"joined %d\n", sum;
"locked %d\n", counter;
"atomic %d\n", acount;
