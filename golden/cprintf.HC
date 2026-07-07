// C varargs through the platform ABI: puts and printf (real C varargs, not
// HolyC's argc/argv convention). All output goes through C stdio, so the
// golden's ordering is deterministic.
extern I64 puts(U8 *s);
extern I64 printf(U8 *fmt, ...);

puts("hello from libc");
printf("%s %d %c\n", "printf", 42, 'x');
printf("pi ~ %.2f\n", 3.14159);
