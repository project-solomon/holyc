# json (reflection)

JSON ⇄ struct mapping by reflection: no per-type serialize or parse code. Add a
field to the class and it's handled.

hcc emits metadata for every class (see `core/KClass.HC`): `Class(name)` returns
a `CHashClass` whose members form a `CMemberLst` chain of `{ str (name), off
(byte offset), size, member_class (type spelling) }`. This program walks it to:

- **serialize** — read each field at its offset, format by type
  (`"U8*"` → string, `"I64"` → number);
- **parse** — match each JSON key to a member by name, write the value at its
  offset.

Fields may be `I64` (a JSON number, or `true`/`false` as `1`/`0`) or `U8*` (a
string). The demo parses a `Book`, serializes it back, and prints its schema.

Uses `Class`/`CHashClass`/`CMemberLst`/`ClassRep` (core, always in scope),
`<Mem.HC>` for `MAlloc`/`Free`, and `<Str.HC>` for `StrCmp`.

## Build & run

```sh
hcc -o json main.HC
./json
```

## Expected output

```
parsed:   title=HolyC | author=Terry Davis | year=2013 | pages=42 | inprint=1
re-emit:  {"title":"HolyC","author":"Terry Davis","year":2013,"pages":42,"inprint":1}
schema (from reflection):
Book 40
U8* title 0 8
U8* author 8 8
I64 year 16 8
I64 pages 24 8
I64 inprint 32 8
```
