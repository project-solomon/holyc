// function pointers: select an operation at runtime.
I64 Add(I64 a, I64 b) { return a + b; }
I64 Mul(I64 a, I64 b) { return a * b; }

I64 (*op)(I64, I64);
op = &Add;
"%d\n", op(3, 4); // 7
op = &Mul;
"%d\n", op(3, 4); // 12
