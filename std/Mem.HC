// Mem.HC — the task heap plus raw byte-buffer utilities.
// `#include <Mem.HC>`.
//
// MAlloc/Free/MSize/HeapExtend are compiler intrinsics (each call lowers
// directly to an IR op, so their prototype bodies are never emitted);
// CAlloc/ReAlloc are ordinary HolyC built on top of them. MemCpy/MemSet/MemCmp
// operate on U8* buffers with an explicit length. A host service, not part of
// the dialect core.
#ifndef __STD_MEM_HC
#define __STD_MEM_HC

// ---- the task heap ----
public U8 *MAlloc(I64 size);                        // allocate size bytes on the task heap; returns the block
public U0  Free(U8 *ptr);                           // free a block returned by MAlloc
public I64 MSize(U8 *ptr);                          // usable size of a block returned by MAlloc
public U8 *HeapExtend(U8 *ptr, I64 old, I64 newsz); // grow the last block in place, else NULL

// CAlloc allocates n zero-filled bytes (C calloc over a flat byte count).
public U8 *CAlloc(I64 n)
{
  U8 *p = MAlloc(n);
  if (p) {
    I64 i;
    for (i = 0; i < n; i++)
      p[i] = 0;
  }
  return p;
}

// ReAlloc resizes the block p (currently oldsz bytes) to newsz bytes. It grows in
// place when p is the heap's last allocation (HeapExtend); otherwise it allocates a
// new block, copies min(oldsz, newsz) bytes, and frees the old one. A NULL p just
// allocates.
public U8 *ReAlloc(U8 *p, I64 oldsz, I64 newsz)
{
  if (!p)
    return MAlloc(newsz);
  U8 *grown = HeapExtend(p, oldsz, newsz);
  if (grown)
    return grown;
  U8 *q = MAlloc(newsz);
  I64 n = oldsz;
  if (newsz < n)
    n = newsz;
  I64 i;
  for (i = 0; i < n; i++)
    q[i] = p[i];
  Free(p);
  return q;
}

// ---- raw byte-buffer utilities (pure HolyC; inline and dead-strip) ----

// Copy n bytes from src to dst (no overlap handling); returns dst.
public U8 *MemCpy(U8 *dst, U8 *src, I64 n)
{
  I64 i;
  for (i = 0; i < n; i++)
    dst[i] = src[i];
  return dst;
}

// Set n bytes of dst to the low byte of c; returns dst.
public U8 *MemSet(U8 *dst, I64 c, I64 n)
{
  I64 i;
  for (i = 0; i < n; i++)
    dst[i] = c;
  return dst;
}

// Compare n bytes: <0, 0, or >0 by the first differing byte (like C memcmp).
public I64 MemCmp(U8 *a, U8 *b, I64 n)
{
  I64 i;
  for (i = 0; i < n; i++)
    if (a[i] != b[i])
      return a[i] - b[i];
  return 0;
}

#endif // __STD_MEM_HC
