// max/min/abs written as empty-armed if/else diamonds, which if-conversion
// flattens to branchless selects (CSEL). Exercised across the sign boundary.
I64 Max(I64 a, I64 b)
{
  I64 m;
  if (a > b)
    m = a;
  else
    m = b;
  return m;
}

I64 Min(I64 a, I64 b)
{
  I64 m;
  if (a < b)
    m = a;
  else
    m = b;
  return m;
}

I64 Abs(I64 x)
{
  I64 neg = -x, r;
  if (x < 0)
    r = neg;
  else
    r = x;
  return r;
}

"%d %d %d\n", Max(3, 7), Max(7, 3), Max(-5, -2);
"%d %d %d\n", Min(3, 7), Min(7, 3), Min(-5, -2);
"%d %d %d\n", Abs(-8), Abs(8), Abs(0);
