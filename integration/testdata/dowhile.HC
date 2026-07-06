// do-while runs its body at least once, even when the condition is false.
I64 n = 0;
do {
  "%d\n", n;
  n++;
} while (n < 3);

I64 m = 10;
do {
  "once %d\n", m;
} while (m < 0);
