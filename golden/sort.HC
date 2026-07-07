// bubble sort, then print the sorted array.
I64 a[6] = {5, 2, 8, 1, 9, 3};
I64 i, j, t;
for (i = 0; i < 6; i++)
  for (j = 0; j < 5 - i; j++)
    if (a[j] > a[j + 1]) {
      t = a[j];
      a[j] = a[j + 1];
      a[j + 1] = t;
    }
for (i = 0; i < 6; i++)
  "%d ", a[i];
"\n";
