// C-style scaled pointer arithmetic: *(p + i) keeps the pointer type and scales
// the offset by the element size.
I64 a[5] = {10, 20, 30, 40, 50};
I64 *p = a;
"%d\n", *(p + 0);   // 10
"%d\n", *(p + 3);   // 40 (offset scaled by 8, not 1)
"%d\n", *(a + 2);   // 30 (array decays, then arithmetic)
"%d\n", (p + 1)[2]; // 40 (indexing a pointer expression)
I64 *q = p + 4;
"%d\n", *q;         // 50
"%d\n", q - p;      // 4  (pointer difference is an element count)

// A byte array confirms the stride really tracks the element type.
U8 s[4];
s[0] = 'h';
s[1] = 'i';
s[2] = '!';
s[3] = 0;
U8 *cp = s;
"%c%c%c\n", *(cp + 0), *(cp + 1), *(cp + 2); // hi!
