// Sum 1..N with a for loop (the README's first program).
I64 Sum(I64 n)
{
  I64 i, s = 0;
  for (i = 1; i <= n; i++)
    s += i;
  return s;
}

"sum(1..100) = %d\n", Sum(100);
