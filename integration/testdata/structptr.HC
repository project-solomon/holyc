// mutate a struct through a pointer.
class Counter { I64 n; };
U0 Bump(Counter *c, I64 by) { c->n += by; }

Counter c;
c.n = 0;
Bump(&c, 5);
Bump(&c, 3);
"%d\n", c.n; // 8
