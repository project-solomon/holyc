# examples

Self-contained HolyC programs, one per subdirectory:

```sh
cd examples/<name>
hcc -o <name> main.HC
./<name>
```

Needs `hcc` and the standard library on `PATH` (both from `install.sh`).

| Example | Shows |
| --- | --- |
| [`threadpool/`](threadpool) | A thread pool over `<Sync.HC>`: `Thread`/`Join`, lock-free dispatch with `AtomicAdd`, and `lock { }`. |
| [`json/`](json) | JSON ⇄ struct mapping by reflection: walk a class's metadata (`Class`, `CMemberLst`) to serialize and parse any struct, no per-type code. |
