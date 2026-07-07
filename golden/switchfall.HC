// switch fallthrough: cases without break fall into the next.
U0 Count(I64 n)
{
  I64 c = 0;
  switch (n) {
    case 1: c++;
    case 2: c++;
    case 3: c++;
    default: c++;
  }
  "%d\n", c;
}

Count(1); // 1 -> 2 -> 3 -> default = 4
Count(3); // 3 -> default = 2
Count(9); // default only = 1
