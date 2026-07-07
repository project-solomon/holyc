// global state mutated across function calls.
I64 counter = 0;
U0 Inc() { counter++; }
U0 Add(I64 n) { counter += n; }

Inc();
Inc();
Add(10);
"%d\n", counter; // 12
