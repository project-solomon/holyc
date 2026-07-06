// unsigned arithmetic wraps around modulo 2^64.
U64 a = 0;
a--;
"%u\n", a; // 2^64 - 1
U64 b = 10, c = 20;
"%u\n", b - c; // 2^64 - 10
