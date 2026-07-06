// dynamic allocation: MAlloc, use the block, then Free.
I64 *p = MAlloc(4 * 8); // room for four I64s
I64 i, sum = 0;
for (i = 0; i < 4; i++)
  p[i] = (i + 1) * 100;
for (i = 0; i < 4; i++)
  sum += p[i];
"%d\n", sum; // 100+200+300+400
Free(p);
"freed\n";
