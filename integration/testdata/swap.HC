// swap two values through pointers.
U0 Swap(I64 *a, I64 *b)
{
  I64 t = *a;
  *a = *b;
  *b = t;
}

I64 x = 3, y = 8;
Swap(&x, &y);
"%d %d\n", x, y; // 8 3
