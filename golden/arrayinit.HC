// a partial array initializer zero-fills the remaining elements.
I64 a[5] = {1, 2, 3};
I64 i, sum = 0;
for (i = 0; i < 5; i++) {
  "%d ", a[i];
  sum += a[i];
}
"\n%d\n", sum;
