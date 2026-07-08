// A fixed-size thread pool.
//
// WORKERS worker threads drain a shared queue of jobs. Each job is claimed
// exactly once with an atomic fetch-and-add on `claimed` (lock-free dispatch),
// so no job runs twice and no lock is needed to hand work out. A separate
// lock { } block guards a shared counter, to show that construct too.
//
// Shows off <Sync.HC>: Thread / Join, AtomicAdd, and the lock { } block.
// Build:  hcc -o threadpool main.HC
// Run:    ./threadpool
#include <Sync.HC>

#define WORKERS 4
#define JOBS 12

// A unit of work: call fn(arg) and keep the result.
class Job {
  I64 (*fn)(I64);
  I64 arg;
};

Job jobs[JOBS];
I64 results[JOBS];
I64 claimed = 0; // next unclaimed job index; bumped atomically by workers
I64 handled = 0; // total jobs run; guarded by the lock block

// Two kinds of job.
I64 Square(I64 x)
{
  return x * x;
}

I64 Fib(I64 n)
{
  I64 a = 0, b = 1, i;
  for (i = 0; i < n; i++) {
    I64 t = a + b;
    a = b;
    b = t;
  }
  return a;
}

// A worker drains the queue: atomically claim the next index; once the index
// runs past the end the queue is empty and the worker exits. Each job writes
// its own results slot, so the output is deterministic no matter how the
// threads interleave.
I64 Worker(I64 id)
{
  I64 mine = 0;
  while (TRUE) {
    I64 i = AtomicAdd(&claimed, 1) - 1; // claim job i (each claimed once)
    if (i >= JOBS)
      break;
    results[i] = jobs[i].fn(jobs[i].arg);
    lock {
      handled++;
    }
    mine++;
  }
  return mine; // how many this worker ran
}

// ---- main ----
I64 i;
for (i = 0; i < JOBS; i++) {
  jobs[i].arg = i;
  if (i & 1)
    jobs[i].fn = &Fib;
  else
    jobs[i].fn = &Square;
}

I64 pool[WORKERS], w;
for (w = 0; w < WORKERS; w++)
  pool[w] = Thread(&Worker, w);

I64 total = 0;
for (w = 0; w < WORKERS; w++)
  total += Join(pool[w]);

"workers ran %d jobs (handled=%d)\n", total, handled;
for (i = 0; i < JOBS; i++) {
  if (i & 1)
    "  job %2d fib    -> %d\n", i, results[i];
  else
    "  job %2d square -> %d\n", i, results[i];
}
