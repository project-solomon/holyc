// StrPrint.HC — the print core: Print/FPrint and the pure-HolyC %-formatter,
// including exact round-half-even float formatting (the Fbn big-integer path).
// Built on StdWrite, the compiler's sole output primitive, so the interpreter
// and every backend produce identical bytes. Part of the always-resident core
// (see core.zig).
//
// StdWrite is a compiler intrinsic: the prototype puts it in scope for the
// type-checker; the compiler lowers each call to an IR op (PrimInst), so its
// prototype body is never emitted. The whole formatter lives in one file
// because its non-public helpers call each other across the integer/float
// split.
#ifndef __CORE_STRPRINT_HC
#define __CORE_STRPRINT_HC

public I64 StdWrite(I64 fd, U8 *buf, I64 count); // write count bytes of buf to fd; returns count

// ---- print core ----------------------------------------------------------
// StdWrite(fd, buf, count) is the compiler's sole output primitive. Everything
// below is ordinary HolyC, so the oracle and native backends produce identical
// bytes. The %-walker (_VFmt) takes the varargs explicitly (argv/argc) so
// Print/FPrint can forward their own varargs to it.

// _Wr writes n bytes of s to fd (n <= 0 writes nothing).
U0 _Wr(I64 fd, U8 *s, I64 n)
{
  if (n > 0)
    StdWrite(fd, s, n);
}

// _Pad writes n copies of byte c to fd (n <= 0 writes nothing).
U0 _Pad(I64 fd, I64 c, I64 n)
{
  U8 ch = c;
  while (n > 0) {
    StdWrite(fd, &ch, 1);
    n = n - 1;
  }
}

// _U64Str writes the base-`base` digits of unsigned `v` into out, most-significant
// first and without a NUL, returning the digit count. `upper` selects A-F over a-f.
I64 _U64Str(U8 *out, U64 v, I64 base, I64 upper)
{
  U8 tmp[24];
  I64 n = 0;
  if (v == 0) {
    tmp[0] = '0';
    n = 1;
  }
  while (v != 0) {
    I64 d = v % base;
    if (d < 10)
      tmp[n] = '0' + d;
    else if (upper)
      tmp[n] = 'A' + d - 10;
    else
      tmp[n] = 'a' + d - 10;
    n = n + 1;
    v = v / base;
  }
  I64 i = 0;
  while (i < n) {
    out[i] = tmp[n - 1 - i];
    i = i + 1;
  }
  return n;
}

// ---- floating-point formatting (pure HolyC, exact round-half-even) ----------
// Exact decimal conversion via a base-2^32 big integer (Fbn): %f/%e/%g are
// correctly rounded and identical in the interpreter and every backend.

// Reinterpret a double as its 64-bit pattern and back (a memory pun).
I64 FltToBits(F64 x) { return *(I64 *)(&x); }
F64 FltFromBits(I64 b) { return *(F64 *)(&b); }

// Fbn is an unsigned big integer: d[0..n-1] little-endian base-2^32 limbs.
class Fbn { I64 n; I64 d[120]; }

// b = v (the low 64 bits as an unsigned magnitude).
U0 FbnSet(Fbn *b, I64 v)
{
  I64 i;
  for (i = 0; i < 120; i++) b->d[i] = 0;
  b->d[0] = v & 0xFFFFFFFF;
  b->d[1] = (v >> 32) & 0xFFFFFFFF;
  b->n = 0;
  if (b->d[1]) b->n = 2;
  else if (b->d[0]) b->n = 1;
}

I64 FbnIsZero(Fbn *b) { return b->n == 0; }

U0 FbnCopy(Fbn *dst, Fbn *src)
{
  I64 i;
  for (i = 0; i < 120; i++) dst->d[i] = src->d[i];
  dst->n = src->n;
}

// b *= m, with 0 < m < 2^31 (so each limb product fits in I64).
U0 FbnMulSmall(Fbn *b, I64 m)
{
  I64 carry = 0, i = 0;
  while (i < b->n || carry) {
    I64 cur = b->d[i] * m + carry;
    b->d[i] = cur & 0xFFFFFFFF;
    carry = cur >> 32;
    i++;
  }
  b->n = i;
}

// b *= 5^p (p >= 0), in chunks of 5^13 (the largest power of five below 2^32).
U0 FbnMul5Pow(Fbn *b, I64 p)
{
  while (p >= 13) { FbnMulSmall(b, 1220703125); p -= 13; }
  if (p > 0) {
    I64 m = 1, k;
    for (k = 0; k < p; k++) m *= 5;
    FbnMulSmall(b, m);
  }
}

// dst = src << bits (bits >= 0). Writes every limb, so dst needs no pre-clear.
U0 FbnShlTo(Fbn *dst, Fbn *src, I64 bits)
{
  I64 limbs = bits / 32, sh = bits % 32, carry = 0, i;
  for (i = 0; i < 120; i++) dst->d[i] = 0;
  for (i = 0; i < src->n; i++) {
    I64 cur = src->d[i];
    I64 lo = ((cur << sh) & 0xFFFFFFFF) | carry;
    I64 idx = i + limbs;
    if (idx < 120) dst->d[idx] = lo;
    if (sh) carry = cur >> (32 - sh);
    else carry = 0;
  }
  I64 top = src->n + limbs;
  if (carry && top < 120) dst->d[top] = carry & 0xFFFFFFFF;
  dst->n = 0;
  for (i = 119; i >= 0; i--)
    if (dst->d[i]) { dst->n = i + 1; break; }
}

// b = round_half_even(b / 2^bits), in place (bits > 0).
U0 FbnShrRound(Fbn *b, I64 bits)
{
  I64 word = bits / 32, bit = bits % 32, i;
  I64 rword = (bits - 1) / 32, rbit = (bits - 1) % 32;
  I64 roundbit = 0;
  if (rword < b->n) roundbit = (b->d[rword] >> rbit) & 1;
  I64 sticky = 0;
  for (i = 0; i < rword; i++)
    if (b->d[i]) sticky = 1;
  if (rword < b->n && (b->d[rword] & ((1 << rbit) - 1))) sticky = 1;
  Fbn out;
  for (i = 0; i < 120; i++) out.d[i] = 0;
  i = 0;
  while (i + word < b->n) {
    I64 lo = b->d[i + word] >> bit;
    if (bit && i + word + 1 < b->n)
      lo |= (b->d[i + word + 1] << (32 - bit)) & 0xFFFFFFFF;
    out.d[i] = lo & 0xFFFFFFFF;
    i++;
  }
  out.n = 0;
  for (i = 119; i >= 0; i--)
    if (out.d[i]) { out.n = i + 1; break; }
  if (roundbit && (sticky || (out.d[0] & 1))) {
    I64 k = 0;
    while (k < 120) {
      out.d[k] = (out.d[k] + 1) & 0xFFFFFFFF;
      if (out.d[k]) break;
      k++;
    }
    if (out.n <= k && k < 120) out.n = k + 1;
  }
  FbnCopy(b, &out);
}

// b /= 10^9, returning the remainder (0 .. 10^9-1). Extracts 9 decimal digits/pass.
I64 FbnDivPow10_9(Fbn *b)
{
  I64 rem = 0, i;
  for (i = b->n - 1; i >= 0; i--) {
    I64 cur = (rem << 32) | b->d[i];
    b->d[i] = cur / 1000000000;
    rem = cur % 1000000000;
  }
  while (b->n > 0 && b->d[b->n - 1] == 0) b->n--;
  return rem;
}

// Extract every decimal digit of b least-significant-first into digs (ASCII),
// returning the count. b is consumed. A zero b yields the single digit '0'.
I64 FbnDigitsLsb(Fbn *b, U8 *digs)
{
  I64 nd = 0;
  if (FbnIsZero(b)) { digs[nd++] = '0'; return nd; }
  while (!FbnIsZero(b)) {
    I64 rem = FbnDivPow10_9(b);
    if (FbnIsZero(b))
      while (rem > 0) { digs[nd++] = '0' + rem % 10; rem /= 10; }
    else {
      I64 k;
      for (k = 0; k < 9; k++) { digs[nd++] = '0' + rem % 10; rem /= 10; }
    }
  }
  return nd;
}

// The %f magnitude of v (finite) with prec fractional digits, NUL-terminated; the
// length is returned. Builds J = round(m*5^P*2^(E+P)) exactly, point P from the right.
I64 FmtFMag(U8 *out, F64 v, I64 prec)
{
  I64 bits = FltToBits(v);
  I64 expf = (bits >> 52) & 0x7FF;
  I64 frac = bits & 0xFFFFFFFFFFFFF;
  I64 mant, e;
  if (expf == 0) { mant = frac; e = -1074; }
  else { mant = frac | (1 << 52); e = expf - 1075; }
  Fbn bn;
  FbnSet(&bn, mant);
  if (mant) {
    FbnMul5Pow(&bn, prec);
    I64 shift = e + prec;
    if (shift >= 0) {
      Fbn t;
      FbnShlTo(&t, &bn, shift);
      FbnCopy(&bn, &t);
    } else {
      FbnShrRound(&bn, -shift);
    }
  }
  U8 digs[1200];
  I64 nd = FbnDigitsLsb(&bn, digs);
  I64 pos = 0, i;
  if (nd > prec)
    for (i = nd - 1; i >= prec; i--) out[pos++] = digs[i];
  else
    out[pos++] = '0';
  if (prec > 0) {
    out[pos++] = '.';
    for (i = prec - 1; i >= 0; i--) {
      if (i < nd) out[pos++] = digs[i];
      else out[pos++] = '0';
    }
  }
  out[pos] = 0;
  return pos;
}

// The significant decimal digits of magnitude mag (>= 0), rounded half-to-even to
// nsig digits (MSB-first), with the decimal exponent of the leading digit in *xout.
U0 SciDigits(F64 mag, I64 nsig, U8 *digs, I64 *xout)
{
  I64 bits = FltToBits(mag);
  I64 expf = (bits >> 52) & 0x7FF;
  I64 frac = bits & 0xFFFFFFFFFFFFF;
  I64 i;
  if (expf == 0 && frac == 0) {
    for (i = 0; i < nsig; i++) digs[i] = '0';
    *xout = 0;
    return;
  }
  I64 m, e;
  if (expf == 0) { m = frac; e = -1074; }
  else { m = frac | (1 << 52); e = expf - 1075; }
  Fbn bn;
  FbnSet(&bn, m);
  I64 pe;
  if (e >= 0) {
    Fbn t;
    FbnShlTo(&t, &bn, e);
    FbnCopy(&bn, &t);
    pe = 0;
  } else {
    FbnMul5Pow(&bn, -e);
    pe = e;
  }
  U8 lsb[1200];
  I64 ll = FbnDigitsLsb(&bn, lsb);
  I64 x0 = (ll - 1) + pe;
  if (ll <= nsig) {
    for (i = 0; i < ll; i++) digs[i] = lsb[ll - 1 - i];
    for (i = ll; i < nsig; i++) digs[i] = '0';
    *xout = x0;
    return;
  }
  for (i = 0; i < nsig; i++) digs[i] = lsb[ll - 1 - i];
  I64 rd = lsb[ll - 1 - nsig] - '0', sticky = 0;
  for (i = nsig + 1; i < ll; i++)
    if (lsb[ll - 1 - i] != '0') { sticky = 1; break; }
  I64 up = 0;
  if (rd > 5) up = 1;
  else if (rd == 5 && (sticky || ((digs[nsig - 1] - '0') & 1))) up = 1;
  if (up) {
    I64 carry = 1, k = nsig - 1;
    while (carry && k >= 0) {
      I64 dv = (digs[k] - '0') + 1;
      if (dv == 10) digs[k] = '0';
      else { digs[k] = '0' + dv; carry = 0; }
      k--;
    }
    if (carry) {
      digs[0] = '1';
      for (i = 1; i < nsig; i++) digs[i] = '0';
      x0++;
    }
  }
  *xout = x0;
}

// Append x as a libc-style exponent (e/E, sign, >= 2 digits) at pos.
I64 PutExp(U8 *out, I64 pos, I64 x, I64 upper)
{
  if (upper) out[pos++] = 'E';
  else out[pos++] = 'e';
  I64 ex = x;
  if (ex < 0) { out[pos++] = '-'; ex = -ex; }
  else out[pos++] = '+';
  U8 eb[8];
  I64 en = 0;
  if (ex == 0) eb[en++] = '0';
  else
    while (ex > 0) { eb[en++] = '0' + ex % 10; ex /= 10; }
  while (en < 2) eb[en++] = '0';
  I64 i;
  for (i = en - 1; i >= 0; i--) out[pos++] = eb[i];
  return pos;
}

// The %e/%E magnitude of v (finite): one leading digit, a prec-digit fraction, exp.
I64 FmtEMag(U8 *out, F64 v, I64 prec, I64 upper)
{
  I64 bits = FltToBits(v);
  F64 mag = FltFromBits(bits & 0x7FFFFFFFFFFFFFFF);
  U8 digs[600];
  I64 x;
  SciDigits(mag, prec + 1, digs, &x);
  I64 pos = 0;
  out[pos++] = digs[0];
  if (prec > 0) {
    out[pos++] = '.';
    I64 i;
    for (i = 1; i <= prec; i++) out[pos++] = digs[i];
  }
  pos = PutExp(out, pos, x, upper);
  out[pos] = 0;
  return pos;
}

// The %g/%G magnitude of v (finite): prec significant figures, fixed or scientific
// by the rounded exponent, trailing zeros trimmed unless alt.
I64 FmtGMag(U8 *out, F64 v, I64 prec, I64 upper, I64 alt)
{
  I64 bits = FltToBits(v);
  F64 mag = FltFromBits(bits & 0x7FFFFFFFFFFFFFFF);
  I64 p = prec, i;
  if (p < 1) p = 1;
  U8 digs[600];
  I64 x;
  SciDigits(mag, p, digs, &x);
  U8 body[2048];
  I64 bn = 0;
  if (x >= -4 && x < p) {
    I64 fp = p - 1 - x;
    if (fp < 0) fp = 0;
    bn = FmtFMag(body, mag, fp);
  } else {
    body[bn++] = digs[0];
    if (p > 1) {
      body[bn++] = '.';
      for (i = 1; i < p; i++) body[bn++] = digs[i];
    }
    bn = PutExp(body, bn, x, upper);
  }
  body[bn] = 0;
  if (!alt) {
    I64 epos = -1;
    for (i = 0; i < bn; i++)
      if (body[i] == 'e' || body[i] == 'E') { epos = i; break; }
    I64 mend = epos;
    if (epos < 0) mend = bn;
    I64 hasdot = 0;
    for (i = 0; i < mend; i++)
      if (body[i] == '.') hasdot = 1;
    if (hasdot) {
      I64 t = mend;
      while (t > 0 && body[t - 1] == '0') t--;
      if (t > 0 && body[t - 1] == '.') t--;
      if (epos >= 0) {
        I64 d = 0;
        for (i = epos; i < bn; i++) { body[t + d] = body[i]; d++; }
        bn = t + d;
      } else {
        bn = t;
      }
      body[bn] = 0;
    }
  }
  I64 pos = 0;
  for (i = 0; i < bn; i++) out[pos++] = body[i];
  out[pos] = 0;
  return pos;
}

// Write the inf/NaN magnitude (no sign) for a non-finite bits, or return -1 if finite.
I64 FmtSpecialMag(U8 *out, I64 bits)
{
  if (((bits >> 52) & 0x7FF) != 0x7FF) return -1;
  I64 pos = 0;
  if (bits & 0xFFFFFFFFFFFFF) {
    out[pos++] = 'N'; out[pos++] = 'a'; out[pos++] = 'N';
  } else {
    out[pos++] = 'i'; out[pos++] = 'n'; out[pos++] = 'f';
  }
  out[pos] = 0;
  return pos;
}

#define _FLT_MINUS 4  // '-' left-justify
#define _FLT_ZERO  8  // '0' zero-pad (after the sign)
#define _FLT_PLUS  16 // '+' always show a sign
#define _FLT_SPACE 32 // ' ' space before a non-negative
#define _FLT_HASH  64 // '#' alternate form (keep %g trailing zeros)

// FmtFloat formats v per conv (f/e/E/g/G) with flags/width/prec into out (NUL-
// terminated), returning the length.
I64 FmtFloat(U8 *out, F64 v, I64 conv, I64 flags, I64 width, I64 prec)
{
  I64 bits = FltToBits(v);
  U8 body[2048];
  I64 blen = FmtSpecialMag(body, bits);
  if (blen < 0) {
    if (conv == 'f') blen = FmtFMag(body, v, prec);
    else if (conv == 'e' || conv == 'E') blen = FmtEMag(body, v, prec, conv == 'E');
    else blen = FmtGMag(body, v, prec, conv == 'G', (flags & _FLT_HASH) != 0);
  }
  U8 sign = 0;
  if (bits >> 63 & 1) sign = '-';
  else if (flags & _FLT_PLUS) sign = '+';
  else if (flags & _FLT_SPACE) sign = ' ';
  I64 fieldlen = blen;
  if (sign) fieldlen++;
  I64 pos = 0, i;
  if (width <= fieldlen) {
    if (sign) out[pos++] = sign;
    for (i = 0; i < blen; i++) out[pos++] = body[i];
  } else if (flags & _FLT_MINUS) {
    if (sign) out[pos++] = sign;
    for (i = 0; i < blen; i++) out[pos++] = body[i];
    for (i = 0; i < width - fieldlen; i++) out[pos++] = ' ';
  } else if (flags & _FLT_ZERO) {
    if (sign) out[pos++] = sign;
    for (i = 0; i < width - fieldlen; i++) out[pos++] = '0';
    for (i = 0; i < blen; i++) out[pos++] = body[i];
  } else {
    for (i = 0; i < width - fieldlen; i++) out[pos++] = ' ';
    if (sign) out[pos++] = sign;
    for (i = 0; i < blen; i++) out[pos++] = body[i];
  }
  out[pos] = 0;
  return pos;
}

// _VFmt walks fmt, writing to fd, pulling arguments from argv (each an 8-byte slot;
// %s/%p read a slot as a pointer, %f/%e/%g read it as an F64). Conversions:
// %d %u %x %X %p %c %s %f %e %E %g %G %%, with '-' '0' '+' ' ' '#' flags, a field
// width, and a precision. An unknown conversion is dropped; returns bytes written.
I64 _VFmt(I64 fd, U8 *fmt, I64 *argv, I64 argc)
{
  I64 i = 0;
  I64 ai = 0;
  while (fmt[i] != 0) {
    U8 c = fmt[i];
    i = i + 1;
    if (c != '%') {
      U8 ch = c;
      StdWrite(fd, &ch, 1);
      goto _vfmt_next;
    }

    I64 left = 0, zero = 0, plus = 0, space = 0, hash = 0;
    while (TRUE) {
      U8 fc = fmt[i];
      if (fc == '-')
        left = 1;
      else if (fc == '0')
        zero = 1;
      else if (fc == '+')
        plus = 1;
      else if (fc == ' ')
        space = 1;
      else if (fc == '#')
        hash = 1;
      else
        break;
      i = i + 1;
    }
    I64 width = 0;
    while (fmt[i] >= '0' && fmt[i] <= '9') {
      width = width * 10 + (fmt[i] - '0');
      i = i + 1;
    }
    I64 prec = -1;
    if (fmt[i] == '.') {
      i = i + 1;
      prec = 0;
      while (fmt[i] >= '0' && fmt[i] <= '9') {
        prec = prec * 10 + (fmt[i] - '0');
        i = i + 1;
      }
    }
    U8 conv = fmt[i];
    i = i + 1;

    // Floating point: the exact formatter builds the whole field; emit it.
    if (conv == 'f' || conv == 'e' || conv == 'E' || conv == 'g' || conv == 'G') {
      F64 v = *(F64 *)(&argv[ai]);
      ai = ai + 1;
      I64 flags = 0;
      if (left) flags |= _FLT_MINUS;
      if (zero) flags |= _FLT_ZERO;
      if (plus) flags |= _FLT_PLUS;
      if (space) flags |= _FLT_SPACE;
      if (hash) flags |= _FLT_HASH;
      I64 fp;
      if (prec >= 0)
        fp = prec;
      else
        fp = 6;
      U8 fbuf[2400];
      I64 flen = FmtFloat(fbuf, v, conv, flags, width, fp);
      _Wr(fd, fbuf, flen);
      goto _vfmt_next;
    }

    // %s formats the caller's string directly and handles its own padding.
    if (conv == 's') {
      U8 *s = (U8 *)argv[ai];
      ai = ai + 1;
      I64 sl = 0;
      while (s[sl] != 0)
        sl = sl + 1;
      if (prec >= 0 && prec < sl)
        sl = prec;
      if (!left)
        _Pad(fd, ' ', width - sl);
      _Wr(fd, s, sl);
      if (left)
        _Pad(fd, ' ', width - sl);
      goto _vfmt_next;
    }

    // Everything else formats into buf, with an optional sign or "0x" prefix.
    U8 buf[24];
    I64 blen = 0;
    U8 sign = 0; // '-' for a negative %d, else 0
    U8 pfx0 = 0; // "0x" for %p
    U8 pfx1 = 0;
    if (conv == '%') {
      buf[0] = '%';
      blen = 1;
    } else if (conv == 'c') {
      buf[0] = argv[ai];
      ai = ai + 1;
      blen = 1;
    } else if (conv == 'd') {
      I64 v = argv[ai];
      ai = ai + 1;
      U64 u;
      if (v < 0) {
        sign = '-';
        u = -v;
      } else {
        u = v;
        if (plus)
          sign = '+';
        else if (space)
          sign = ' ';
      }
      blen = _U64Str(buf, u, 10, 0);
    } else if (conv == 'u') {
      U64 v = argv[ai];
      ai = ai + 1;
      blen = _U64Str(buf, v, 10, 0);
    } else if (conv == 'x') {
      U64 v = argv[ai];
      ai = ai + 1;
      blen = _U64Str(buf, v, 16, 0);
    } else if (conv == 'X') {
      U64 v = argv[ai];
      ai = ai + 1;
      blen = _U64Str(buf, v, 16, 1);
    } else if (conv == 'p') {
      U64 v = argv[ai];
      ai = ai + 1;
      pfx0 = '0';
      pfx1 = 'x';
      blen = _U64Str(buf, v, 16, 0);
    } else {
      goto _vfmt_next; // unknown conversion: drop the spec
    }

    I64 total = blen;
    if (sign != 0)
      total = total + 1;
    if (pfx0 != 0)
      total = total + 2;

    if (!left && !zero)
      _Pad(fd, ' ', width - total);
    if (sign != 0)
      StdWrite(fd, &sign, 1);
    if (pfx0 != 0) {
      StdWrite(fd, &pfx0, 1);
      StdWrite(fd, &pfx1, 1);
    }
    if (!left && zero)
      _Pad(fd, '0', width - total);
    _Wr(fd, buf, blen);
    if (left)
      _Pad(fd, ' ', width - total);
  _vfmt_next:;
  }
  return 0;
}

// Print formats fmt with its arguments to standard output (fd 1).
public U0 Print(U8 *fmt, ...)
{
  _VFmt(1, fmt, argv, argc);
}

// FPrint formats fmt with its arguments to file descriptor fd.
public I64 FPrint(I64 fd, U8 *fmt, ...)
{
  return _VFmt(fd, fmt, argv, argc);
}

#endif // __CORE_STRPRINT_HC
