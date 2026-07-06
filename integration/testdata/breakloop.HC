// break exits a loop early; odd values below 10 are summed.
I64 i, sum = 0;
for (i = 1; i <= 20; i++) {
  if (i > 9)
    break;
  if (i % 2 == 1)
    sum += i;
}
"%d\n", sum; // 1+3+5+7+9
