// Function-like (parameterized) macros — a C extension over TempleOS HolyC:
// arguments, nested/rescanned expansion, variadics (__VA_ARGS__), the `#`
// stringize and `##` paste operators, and GNU `, ## __VA_ARGS__` comma elision.
#define SQ(x)       ((x) * (x))
#define ADD(a, b)   ((a) + (b))
#define APPLY(f, x) f(x)
#define STR(x)      #x
#define XSTR(x)     STR(x)
#define CAT(a, b)   a ## b
#define VER         3
#define val_hi      111

"SQ(3+1)      = %d\n", SQ(3 + 1);
"ADD(SQ(3),8) = %d\n", ADD(SQ(3), 8);
"APPLY(SQ,5)  = %d\n", APPLY(SQ, 5);
"STR(VER)     = %s\n", STR(VER);
"XSTR(VER)    = %s\n", XSTR(VER);
"CAT(val_,hi) = %d\n", CAT(val_, hi);

// A function-like name not followed by `(` stays an ordinary identifier.
I64 SQ = 42;
"bare SQ      = %d\n", SQ;

// Variadic forwarding and comma elision.
#define PRN(...)     __VA_ARGS__
#define P(fmt, ...)  fmt, ## __VA_ARGS__
PRN("va: %d %d\n", 7, 8);
P("elision: none\n");
P("elision: %d\n", 5);

#if ADD(1, 1) == 2
"#if with a function-like macro\n";
#endif
