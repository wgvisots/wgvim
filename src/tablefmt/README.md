# tablefmt

A post-processor for clang-format that turns runs of similar lines into
tables.  clang-format does the formatting; tablefmt adds the alignment it
can't do: padding inside brackets, semicolon and comma columns, and no space
before block braces.

```cpp
struct MyStruct{
    double              a       {0.0};
    std::int32_t        b       {0  };
    std::string         c       {   };
    std::vector<double> whatsits{   };
};

void to_json(nlohmann::json& me, const MyStruct& d){
    me["a"       ] = d.a       ;
    me["b"       ] = d.b       ;
    me["c"       ] = d.c       ;
    me["whatsits"] = d.whatsits;
}
```

## Build and install

```sh
cmake -S . -B build && cmake --build build
ctest --test-dir build              # optional: regression tests
sudo cmake --install build          # or copy build/tablefmt somewhere on $PATH
cp .clang-format ~/your/project/    # clang-format finds it by walking up from each file
```

Needs a C++20 compiler.  The `.clang-format` works with clang-format 18 and
newer (tested with 18 and 23).

## Use

```sh
clang-format file.cpp | tablefmt          # print the result
clang-format -i file.cpp && tablefmt -i file.cpp
```

Always run clang-format first.  tablefmt is idempotent by itself, but it
expects clang-format's spacing as input.

## How tables are formed

One rule, applied the same way everywhere, so you can predict the shape:

1. Consecutive lines with the same indentation and the same *shape* form a
   table.  A blank line ends a table.  A comment-only line doesn't.
2. The shape is the sequence of brackets, commas, semicolons, spaced
   operators, and words.  Lines must match in shape, with two allowances:
   - After the first `=` (or `+=`, `<<=`, ...), the right-hand sides may
     differ, and all assignment operators count as the same operator.
   - A trailing comma is optional, so the last row of an initializer list
     still joins the table.
3. Every position the lines share becomes a column.  Where they differ
   (different contents inside a bracket, say), that span becomes one cell.
   Cells are left-aligned and padded on the right, which is what lines up the
   closing brackets, commas, and semicolons.  Assignment operators are
   right-aligned, the way clang-format's `AlignCompound` does it.
4. If lines have different numbers of words (`const int x` and `double y`),
   the last word, usually the name, gets its own column.  If any line has only
   one word (`int x` and `x`), the words stay together.
5. A word ending in `:` (`case 1:`, `default:`) is a column boundary, so
   `case` rows line up with each other but not with `default:`.

tablefmt never touches preprocessor lines, block comments, multi-line raw
strings, or anything between `// clang-format off` and `// clang-format on`
(or `// tablefmt off` and `// tablefmt on`).  It only ever changes whitespace:
each rewritten line is re-lexed and compared token-for-token with the
original, and on any mismatch the line is left alone and a warning goes to
stderr.

## Options

| Option                 | Effect                                                         |
|------------------------|----------------------------------------------------------------|
| `-i`                   | Edit files in place.                                           |
| `--lines=N:M`          | Only touch tables that overlap lines N..M.  Repeatable.        |
| `--column-limit=N`     | Leave a table alone if aligning it would go past column N.     |
| `--hug-commas`         | `{1,   2  }` instead of `{1  , 2  }`.                           |
| `--no-attach-braces`   | Keep `struct X {` instead of `struct X{`.                      |
| `--no-across-comments` | Comment-only lines end a table.                                |

## In wgvim

wgvim builds tablefmt from this directory and installs it next to the `wgvim` executable.
Its plugin (`runtime/plugin/tablefmt.lua`) replaces the Vim plugin this tool had:

- `:TableFmt` runs clang-format, then tablefmt, on the buffer; `:'<,'>TableFmt` on a range.
- `let g:tablefmt_gq = 1` makes `gq` run tablefmt alone in C and C++ buffers.
- `let g:tablefmt_on_save = 1` formats on every write. One `u` undoes it.

See `:help wgvim-tablefmt`. Under wgvim's sandbox, the `.clang-format` must be inside the
project.

## Include ordering

The `.clang-format` sorts includes from hardest to edit to easiest:

1. C standard headers (`<assert.h>`), then the C++ versions (`<cstring>`),
   then the C++ standard library (`<vector>`), all in one block
2. System headers (`<unistd.h>`, `<sys/...>`, `<linux/...>`, `<windows.h>`)
3. Third-party headers: anything else in angle brackets
4. Your project's headers: anything in quotes

Within a group, headers sort alphabetically, so `<cstdint>` comes before
`<cstring>`.  clang-format normally hoists `foo.hpp` to the top of `foo.cpp`.
That is turned off (`IncludeIsMainRegex`), so your own headers always come
last.

## Why not a clang-format plugin?

clang-format has no plugin interface.  The alternative is patching LLVM's
`WhitespaceManager` and maintaining a fork of LLVM, which is far more work
than an 800-line post-processor.  Since tablefmt only touches whitespace, it
composes cleanly with whichever clang-format version you have.

## Known limits

- Widths count Unicode code points, so wide characters (CJK, emoji) in string
  literals throw off alignment slightly.
- A few inputs that are not code (lines starting with `=`, runs of NUL bytes)
  are not idempotent, or make the safety net keep a line unchanged
  (test/fuzz/tablefmt_fuzzer.cpp, strict mode).
- clang-format is sometimes not idempotent on very large macros.  tablefmt
  doesn't touch macros, so it can't help there.
