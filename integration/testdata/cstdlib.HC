// C standard library interop: computation through `extern` C-ABI imports
// (pointer, double, and long signatures), output through HolyC's own print so
// the golden has a single, deterministic output channel.
extern I64 strlen(U8 *s);
extern F64 sqrt(F64 x);
extern F64 pow(F64 x, F64 y);
extern I64 labs(I64 n);

I64 len = strlen("holyc");
"strlen(\"holyc\") = %d\n", len;

I64 root = sqrt(144.0);
"sqrt(144) = %d\n", root;

I64 p = pow(2.0, 10.0);
"pow(2,10) = %d\n", p;

"labs(-42) = %d\n", labs(-42);
