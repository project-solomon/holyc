// Str.HC — C-string utilities, in pure HolyC.
//
// Part of the HolyC standard library: on-disk source shipped with the
// toolchain and pulled in with `#include <Str.HC>`. Unlike the prelude, none
// of this is implicit — a program opts in. The bodies are ordinary HolyC, so
// the LLVM backend inlines and dead-strips them per program.
#ifndef __STD_STR_HC
#define __STD_STR_HC

// Length of the NUL-terminated string s, not counting the terminator.
public I64 StrLen(U8 *s)
{
  I64 n = 0;
  while (s[n])
    n++;
  return n;
}

// Lexicographic compare: <0 if a<b, 0 if equal, >0 if a>b (like C strcmp).
public I64 StrCmp(U8 *a, U8 *b)
{
  while (*a && *a == *b) {
    a++;
    b++;
  }
  return *a - *b;
}

// Copy src (with its NUL) into dst; returns dst.
public U8 *StrCpy(U8 *dst, U8 *src)
{
  I64 i = 0;
  while (src[i]) {
    dst[i] = src[i];
    i++;
  }
  dst[i] = 0;
  return dst;
}

// Append src (with its NUL) onto the end of dst; returns dst.
public U8 *StrCat(U8 *dst, U8 *src)
{
  StrCpy(dst + StrLen(dst), src);
  return dst;
}

// First occurrence of needle in haystack, or NULL. An empty needle matches
// at the start.
public U8 *StrFind(U8 *haystack, U8 *needle)
{
  I64 nlen = StrLen(needle);
  if (!nlen)
    return haystack;
  while (*haystack) {
    I64 i = 0;
    while (i < nlen && haystack[i] == needle[i])
      i++;
    if (i == nlen)
      return haystack;
    haystack++;
  }
  return NULL;
}

#endif // __STD_STR_HC
