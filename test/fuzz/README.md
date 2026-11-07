# wgvim fuzz tests

libFuzzer harnesses for code that parses untrusted bytes:

| Harness | Code under test | Input it models |
|---|---|---|
| `vterm_fuzzer.c` | `src/nvim/vterm` (terminal emulator) | Output of a program running in `:terminal`, configured as `terminal.c` does (UTF-8, altscreen, reflow, scrollback, fallbacks; plus libvterm's OSC 52 decoder), with a resize and keyboard/mouse input part-way |
| `termkey_fuzzer.c` | `src/nvim/tui/termkey` (terminal input parser) | Bytes from the terminal wgvim runs in (keys, mouse, paste, OSC/DCS/APC replies), configured as `tui/input.c` does, pushed in chunks |
| `treesitter_fuzzer.c` | The Tree-sitter runtime and one bundled parser, built from the `deps/` sources (one binary per language: `treesitter_<lang>_fuzzer`, for c, cpp, diff, lua, vim, vimdoc, query, markdown, markdown_inline) | A file opened in wgvim: parsed in line-sized chunks as wgvim's buffer reader does, every node visited, the language's queries from `runtime/queries` run over it; then an edit and an incremental reparse (changed ranges, queries again), and a parse of only some ranges, as for an injected language |

Seed inputs are in `corpus/<name>/`. The first bytes of each input are a small header (sizes,
flags, chunking) read by the harness; see the top of `LLVMFuzzerTestOneInput`.

## Build

Needs clang with its compiler-rt runtimes (libFuzzer, ASan, UBSan). Use a separate build
directory; the hardening flags are turned off because `_FORTIFY_SOURCE` conflicts with ASan.

    cmake -S . -B build-fuzz -G Ninja -D CMAKE_C_COMPILER=clang \
      -D CMAKE_BUILD_TYPE=RelWithDebInfo -D WGVIM_FUZZ=ON -D WGVIM_HARDENING=OFF
    cmake --build build-fuzz --target fuzzers        # build-fuzz/bin/*_fuzzer
    cmake --build build-fuzz --target nvim           # optional: an ASan/UBSan editor binary

If the link step says `libclang_rt.fuzzer-x86_64.a` is missing, the distribution's clang lacks
compiler-rt (Ubuntu: package `libclang-rt-18-dev`). Without a package mirror it can be built from
the matching `llvm-project` tag (`compiler-rt/`, standalone, `COMPILER_RT_SANITIZERS_TO_BUILD=asan`,
`COMPILER_RT_BUILD_LIBFUZZER=ON`) and copied into `$(clang -print-resource-dir)/lib/linux/`.

## Run

    mkdir -p /tmp/fz/vterm && cp test/fuzz/corpus/vterm/* /tmp/fz/vterm/
    build-fuzz/bin/vterm_fuzzer /tmp/fz/vterm -max_total_time=600 -timeout=10 -max_len=8192

    build-fuzz/bin/termkey_fuzzer test/fuzz/corpus/termkey -runs=0   # just replay the seeds

    # Tree-sitter: the corpus is per language; $TS_FUZZ_NO_QUERIES skips the queries, for a
    # several times faster run on the parser and its external scanner alone.
    build-fuzz/bin/treesitter_c_fuzzer /tmp/fz/c -max_total_time=600 -timeout=10 -max_len=4096

The Tree-sitter harnesses need the dependencies unpacked (`make deps`): they compile the
runtime and parser sources from `.deps/build/src/`. The libraries the editor links are not
instrumented, so a separate build with coverage and sanitizers is the only way to fuzz them.

A crash or hang writes `crash-*` / `timeout-*` next to the current directory (or under
`-artifact_prefix=`). Reproduce with `build-fuzz/bin/<name>_fuzzer <file>`. Add the input to
`corpus/<name>/` once fixed, and a functional test if the bug is reachable from the editor.

## Findings so far

All fixed; details in SECURITY-AUDIT.md row 23. Crash inputs are kept in `corpus/` (`regress-*`).

Tree-sitter (2026-11-07): about 430,000 inputs over the nine parsers, no memory errors, hangs
or out-of-memory; see "Fuzzing of dependencies" in SECURITY-AUDIT.md.

- vterm: REP (`ESC [ b`) with no preceding character looped forever and froze the editor.
- vterm: a CSI with more than 32 parameters overflowed `args[]` on the heap (editor SIGSEGV
  from `:terminal` output).
- vterm: one-past-the-end write in the UTF-8 decoder; cursor restore (`ESC 8`) after a resize
  writing outside the screen; inverted scroll region after a resize (negative `memmove`); column
  −1 with double-width lines on a 1-column terminal; integer overflows in CSI/OSC numbers and
  cursor arithmetic; negative left shift in DECRQSS.
- termkey: stack buffer overflow in CSI subparameter parsing; uninitialized pointer read for
  `ESC [ u`; out-of-bounds `c0[-1]` read for negative CSI-u key codes; assert on non-digit CSI
  parameter bytes.
