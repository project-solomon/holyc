// Integer arithmetic and operator precedence.
I64 a = 7, b = 3;
"%d %d %d %d %d\n", a + b, a - b, a * b, a / b, a % b;
"%d\n", 2 + 3 * 4 - 10 / 2; // 2 + 12 - 5
"%d\n", (2 + 3) * 4;        // grouping
"%d\n", 1 << 4 | 1;        // shift binds tighter than or
"%d\n", -a + b * 2;        // unary minus
