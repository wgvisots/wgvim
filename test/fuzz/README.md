# wgvim fuzz tests

libFuzzer harnesses for code that parses untrusted bytes:

| Harness | Code under test | Input it models |
|---|---|---|
| `vterm_fuzzer.c` | `src/nvim/vterm` (terminal emulator) | Output of a program running in `:terminal`, configured as `terminal.c` does (UTF-8, altscreen, reflow, scrollback, OSC 52 selection, fallbacks), with a resize and keyboard/mouse input part-way |
| `termkey_fuzzer.c` | `src/nvim/tui/termkey` (terminal input parser) | Bytes from the terminal wgvim runs in (keys, mouse, paste, OSC/DCS/APC replies), configured as `tui/input.c` does, pushed in chunks |

Seed inputs are in `corpus/<name>/`. The first bytes of each input are a small header (sizes,
flags, chunking) read by the harness; see the top of `LLVMFuzzerTestOneInput`.

## Build

Needs clang with its compiler-rt runtimes (libFuzzer, ASan, UBSan). Use a separate build
directory; the hardening flags are turned off because `_FORTIFY_SOURCE` conflicts with ASan.

    cmake -S . -B build-fuzz -G Ninja -D CMAKE_C_COMPILER=clang \
      -D CMAKE_BUILD_TYPE=RelWithDebInfo -D WGVIM_FUZZ=ON -D WGVIM_HARDENING=OFF
    cmake --build build-fuzz --target fuzzers        # build-fuzz/bin/{vterm,termkey}_fuzzer
    cmake --build build-fuzz --target nvim           # optional: an ASan/UBSan editor binary

If the link step says `libclang_rt.fuzzer-x86_64.a` is missing, the distribution's clang lacks
compiler-rt (Ubuntu: package `libclang-rt-18-dev`). Without a package mirror it can be built from
the matching `llvm-project` tag (`compiler-rt/`, standalone, `COMPILER_RT_SANITIZERS_TO_BUILD=asan`,
`COMPILER_RT_BUILD_LIBFUZZER=ON`) and copied into `$(clang -print-resource-dir)/lib/linux/`.

## Run

    mkdir -p /tmp/fz/vterm && cp test/fuzz/corpus/vterm/* /tmp/fz/vterm/
    build-fuzz/bin/vterm_fuzzer /tmp/fz/vterm -max_total_time=600 -timeout=10 -max_len=8192

    build-fuzz/bin/termkey_fuzzer test/fuzz/corpus/termkey -runs=0   # just replay the seeds

A crash or hang writes `crash-*` / `timeout-*` next to the current directory (or under
`-artifact_prefix=`). Reproduce with `build-fuzz/bin/<name>_fuzzer <file>`. Add the input to
`corpus/<name>/` once fixed, and a functional test if the bug is reachable from the editor.

## Findings so far

- `vterm`: REP (`ESC [ b`) with no preceding character looped forever, freezing the editor
  (it then ignored SIGTERM). A program only had to print three bytes in `:terminal`. Fixed in
  `src/nvim/vterm/state.c`; regression test in `test/functional/terminal/parser_spec.lua`.
