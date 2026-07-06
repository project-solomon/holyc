// MAllocFree.HC — the task heap. MAlloc/Free/MSize/HeapExtend are compiler
// intrinsics: the prototypes put them in scope for the type-checker, and the
// compiler lowers each call directly to an IR op (PrimInst), so their prototype
// bodies are never emitted. ReAlloc/CAlloc are ordinary HolyC built on top of them.
// Part of the always-resident prelude (see Lib.HC).
#ifndef __PRELUDE_MEM_MALLOCFREE_HC
#define __PRELUDE_MEM_MALLOCFREE_HC

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

#endif // __PRELUDE_MEM_MALLOCFREE_HC
