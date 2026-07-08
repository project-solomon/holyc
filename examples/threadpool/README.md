# threadpool

`WORKERS` threads drain a shared job queue. Each job is claimed once with an
atomic fetch-and-add on a shared index (`AtomicAdd`), so dispatch is lock-free
and no job runs twice; each job writes its own results slot, so the output is
deterministic. A `lock { }` block guards a shared counter.

From `<Sync.HC>`: `Thread`/`Join`, `AtomicAdd`, and `lock { }` (the TempleOS
LOCK block, whose read-modify-writes compile to atomic instructions).

## Build & run

```sh
hcc -o threadpool main.HC
./threadpool
```

## Expected output

```
workers ran 12 jobs (handled=12)
  job  0 square -> 0
  job  1 fib    -> 1
  job  2 square -> 4
  job  3 fib    -> 2
  job  4 square -> 16
  job  5 fib    -> 5
  job  6 square -> 36
  job  7 fib    -> 13
  job  8 square -> 64
  job  9 fib    -> 34
  job 10 square -> 100
  job 11 fib    -> 89
```
