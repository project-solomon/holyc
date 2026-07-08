// A JSON <-> struct mapper driven entirely by REFLECTION.
//
// The compiler emits class metadata for every class you define (see the
// core's KClass.HC): Class(name) returns a CHashClass, whose member_lst is a
// chain of CMemberLst { str (name), off (byte offset), size, member_class (the
// type spelling, e.g. "I64" or "U8*") }. This program walks that metadata to:
//
//   * serialize ANY struct to JSON  (read each field by offset, format by type)
//   * parse a JSON object straight into a struct's fields, matched BY NAME
//
// There is no per-type serialize/parse code — add a field to the class and it
// is handled automatically. Supported field types: I64 (and bool as 0/1) and
// U8* (string). `#include <Mem.HC>` for MAlloc/Free.
//
// Build:  hcc -o json main.HC
// Run:    ./json
#include <Mem.HC> // MAlloc / Free
#include <Str.HC> // StrCmp

// The data model: a plain struct. No annotations, no schema — the class
// metadata IS the schema.
class Book {
  U8 *title;
  U8 *author;
  I64 year;
  I64 pages;
  I64 inprint; // parsed from a JSON bool
};

// ---- reflection helper ----

// The member named `name` in class c, or NULL.
CMemberLst *MemberFind(CHashClass *c, U8 *name)
{
  CMemberLst *m = c->member_lst_and_root;
  while (m) {
    if (StrCmp(m->str, name) == 0)
      return m;
    m = m->next;
  }
  return NULL;
}

// ---- serialize: struct -> JSON, by walking the class metadata ----
U0 JsonEmit(U8 *class_name, U8 *obj)
{
  CHashClass *c = Class(class_name);
  if (!c) {
    Print("null");
    return;
  }
  Print("{");
  CMemberLst *m = c->member_lst_and_root;
  I64 first = TRUE;
  while (m) {
    if (!first)
      Print(",");
    first = FALSE;
    Print("\"%s\":", m->str);
    if (StrCmp(m->member_class, "U8*") == 0) {
      U8 *s = *(U8 **)(obj + m->off);
      if (s)
        Print("\"%s\"", s);
      else
        Print("null");
    } else {
      Print("%d", *(I64 *)(obj + m->off)); // I64 (and bool)
    }
    m = m->next;
  }
  Print("}");
}

// ---- a tiny JSON scanner ----
class Scan {
  U8 *s;
  I64 i;
};

U0 SkipWs(Scan *sc)
{
  while (sc->s[sc->i] == ' ' || sc->s[sc->i] == '\t' ||
         sc->s[sc->i] == '\n' || sc->s[sc->i] == '\r')
    sc->i++;
}

// Parse a quoted string at the opening quote; returns a fresh NUL-terminated
// copy (with minimal escapes) and advances past the closing quote.
U8 *ParseStr(Scan *sc)
{
  sc->i++; // opening quote
  I64 from = sc->i;
  I64 n = 0;
  while (sc->s[sc->i] && sc->s[sc->i] != '"') { // measure the decoded length
    if (sc->s[sc->i] == '\\' && sc->s[sc->i + 1])
      sc->i++;
    sc->i++;
    n++;
  }
  U8 *out = MAlloc(n + 1);
  sc->i = from;
  I64 k = 0;
  while (sc->s[sc->i] && sc->s[sc->i] != '"') { // copy, decoding escapes
    U8 ch = sc->s[sc->i];
    if (ch == '\\' && sc->s[sc->i + 1]) {
      sc->i++;
      U8 e = sc->s[sc->i];
      if (e == 'n')
        ch = '\n';
      else if (e == 't')
        ch = '\t';
      else
        ch = e; // \" \\ / etc: literal
    }
    out[k] = ch;
    k++;
    sc->i++;
  }
  out[k] = 0;
  if (sc->s[sc->i] == '"')
    sc->i++; // closing quote
  return out;
}

// Parse an integer (optional leading '-'); advances past it.
I64 ParseInt(Scan *sc)
{
  I64 neg = FALSE;
  if (sc->s[sc->i] == '-') {
    neg = TRUE;
    sc->i++;
  }
  I64 v = 0;
  while (sc->s[sc->i] >= '0' && sc->s[sc->i] <= '9') {
    v = v * 10 + (sc->s[sc->i] - '0');
    sc->i++;
  }
  if (neg)
    return -v;
  return v;
}

// ---- parse: JSON object -> struct, each value written by field type ----
U0 JsonParse(U8 *class_name, U8 *obj, U8 *text)
{
  CHashClass *c = Class(class_name);
  if (!c)
    return;
  Scan sc;
  sc.s = text;
  sc.i = 0;
  SkipWs(&sc);
  if (sc.s[sc.i] != '{')
    return;
  sc.i++;
  while (TRUE) {
    SkipWs(&sc);
    if (sc.s[sc.i] == '}' || sc.s[sc.i] == 0)
      break;
    U8 *key = ParseStr(&sc);
    SkipWs(&sc);
    if (sc.s[sc.i] == ':')
      sc.i++;
    SkipWs(&sc);
    CMemberLst *m = MemberFind(c, key); // reflection: key -> member
    U8 ch = sc.s[sc.i];
    if (ch == '"') {
      U8 *val = ParseStr(&sc);
      if (m && StrCmp(m->member_class, "U8*") == 0)
        *(U8 **)(obj + m->off) = val; // write the pointer at the field offset
    } else if (ch == 't' || ch == 'f') {
      I64 b = ch == 't';
      while (sc.s[sc.i] >= 'a' && sc.s[sc.i] <= 'z') // skip true/false
        sc.i++;
      if (m)
        *(I64 *)(obj + m->off) = b;
    } else {
      I64 v = ParseInt(&sc);
      if (m)
        *(I64 *)(obj + m->off) = v; // write the integer at the field offset
    }
    Free(key);
    SkipWs(&sc);
    if (sc.s[sc.i] == ',')
      sc.i++;
  }
}

// ---- demo: parse JSON into a Book, then serialize it back ----
U8 *input = "{ \"title\": \"HolyC\", \"author\": \"Terry Davis\", \"year\": 2013, \"pages\": 42, \"inprint\": true }";

Book b;
b.title = NULL;
b.author = NULL;
b.year = 0;
b.pages = 0;
b.inprint = 0;

JsonParse("Book", &b, input);
"parsed:   title=%s | author=%s | year=%d | pages=%d | inprint=%d\n",
    b.title, b.author, b.year, b.pages, b.inprint;

"re-emit:  ";
JsonEmit("Book", &b);
"\n";

// The mapper is generic; the schema comes straight from the metadata:
"schema (from reflection):\n";
ClassRep("Book");
