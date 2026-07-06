// pointer arithmetic: pointer increment and indexing over an array.
I64 a[5] = {10, 20, 30, 40, 50};
I64 *p = a;
"%d\n", p[0]; // 10
"%d\n", p[2]; // 30
p++;
"%d\n", p[0]; // 20
"%d\n", p[2]; // 40
"%d\n", a[4]; // 50
