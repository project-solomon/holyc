// Standard library <Str.HC>: string utilities, resolved from HCC_ROOT/std.
#include <Str.HC>

U8 buf[32];
StrCpy(buf, "holy");
StrCat(buf, "c");
"len=%d\n", StrLen(buf);
"buf=%s\n", buf;
"cmp_eq=%d\n", StrCmp("abc", "abc");
"cmp_lt=%d\n", StrCmp("abc", "abd") < 0;
"cmp_gt=%d\n", StrCmp("abd", "abc") > 0;
"found=%d\n", StrFind("hello world", "world") != NULL;
"nfound=%d\n", StrFind("hello", "xyz") == NULL;
