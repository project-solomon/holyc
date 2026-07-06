// compound pointer assignment (+=, -=) scales the offset by the element size.
I64 a[6] = {10, 20, 30, 40, 50, 60};
I64 *p = a;
I64 step = 2;
p += step;
"%d\n", *p; // 30 (advanced two I64s)
p += 1;
"%d\n", *p; // 40
p -= 3;
"%d\n", *p; // 10 (back to the start)

// the stride tracks the element type: a byte array steps by 1.
U8 s[5];
s[0] = 'a';
s[1] = 'b';
s[2] = 'c';
s[3] = 'd';
s[4] = 0;
U8 *cp = s;
cp += 3;
"%c\n", *cp; // d
