# wgvim functional-test coverage

Generated 2026-11-01 from commit c568ed1 with `cmake -D CMAKE_BUILD_TYPE=Debug -D ENABLE_GCOV=ON`, running the functional suite only (`functionaltest-parallel`: 10,045 passed, 77 skipped, 23 failed — 22 tab-line screen tests that fail only in Debug builds, and `man_spec`, which needs a real `man`). Regenerate with `scripts/coverage-summary.py <build-dir> .`. Covers the editor's own C code in `src/`; LuaJIT, libuv and other dependencies are not instrumented. For comparison, functional + old-style suites together cover 92.4% of lines.

Source: 206 .gcda files, 238 source files under `src/`.

| | Covered | Total | % |
|---|---:|---:|---:|
| Lines | 134272 | 170520 | 78.7 |
| Functions | 7796 | 8586 | 90.8 |

## By directory

| Directory | Lines % | Lines (hit/total) | Functions % |
|---|---:|---:|---:|
| `src/cjson` | 75.8 | 798/1053 | 84.8 |
| `src/klib` | 0.0 | 0/3 | 0.0 |
| `src/lpeg` | 86.3 | 1696/1965 | 93.0 |
| `src/mpack` | 82.2 | 1250/1521 | 87.6 |
| `src/nvim` | 77.8 | 99377/127782 | 90.6 |
| `src/nvim/api` | 94.4 | 4807/5094 | 94.9 |
| `src/nvim/api/private` | 95.4 | 648/679 | 98.3 |
| `src/nvim/eval` | 75.9 | 10631/14013 | 87.4 |
| `src/nvim/event` | 94.3 | 937/994 | 95.7 |
| `src/nvim/lib` | 100.0 | 12/12 | 0.0 |
| `src/nvim/lua` | 90.1 | 3427/3804 | 93.1 |
| `src/nvim/msgpack_rpc` | 90.9 | 1072/1179 | 97.5 |
| `src/nvim/os` | 75.1 | 2044/2721 | 89.1 |
| `src/nvim/tui` | 87.3 | 2082/2384 | 99.2 |
| `src/nvim/tui/termkey` | 68.8 | 944/1372 | 89.2 |
| `src/nvim/viml/parser` | 93.4 | 1253/1342 | 83.3 |
| `src/nvim/vterm` | 67.4 | 2199/3261 | 94.6 |
| `src/xdiff` | 81.7 | 1095/1341 | 93.1 |

## Least-covered files with more than 200 instrumented lines

| File | Lines % | Lines (hit/total) | Functions % |
|---|---:|---:|---:|
| `src/nvim/spellfile.c` | 33.1 | 927/2800 | 52.7 |
| `src/nvim/indent_c.c` | 34.0 | 695/2046 | 69.0 |
| `src/nvim/testing.c` | 39.5 | 192/486 | 61.5 |
| `src/nvim/digraph.c` | 46.4 | 178/384 | 45.8 |
| `src/nvim/textobject.c` | 47.5 | 450/947 | 82.6 |
| `src/nvim/eval/list.c` | 54.4 | 242/445 | 82.6 |
| `src/mpack/conv.c` | 56.9 | 120/211 | 69.6 |
| `src/nvim/spell.c` | 57.5 | 1032/1794 | 72.2 |
| `src/nvim/spellsuggest.c` | 57.5 | 984/1710 | 69.2 |
| `src/nvim/menu.c` | 57.8 | 603/1043 | 79.1 |
| `src/nvim/sign.c` | 58.2 | 501/861 | 74.0 |
| `src/nvim/vterm/state.c` | 59.4 | 896/1509 | 93.6 |
| `src/nvim/tui/termkey/termkey.c` | 60.6 | 359/592 | 85.7 |
| `src/nvim/vterm/pen.c` | 62.1 | 247/398 | 100.0 |
| `src/nvim/cmdhist.c` | 62.6 | 236/377 | 80.0 |
| `src/nvim/profile.c` | 63.8 | 292/458 | 81.6 |
| `src/nvim/regexp.c` | 64.8 | 4492/6929 | 91.9 |
| `src/nvim/strings.c` | 64.8 | 1051/1621 | 81.9 |
| `src/nvim/arglist.c` | 64.9 | 401/618 | 75.0 |
| `src/nvim/quickfix.c` | 65.0 | 2430/3737 | 77.4 |
| `src/nvim/ex_eval.c` | 65.9 | 581/881 | 93.2 |
| `src/nvim/cmdexpand.c` | 66.7 | 1505/2256 | 74.2 |
| `src/nvim/tui/terminfo.c` | 68.3 | 293/429 | 100.0 |
| `src/nvim/os/shell.c` | 68.7 | 431/627 | 87.5 |
| `src/nvim/eval/funcs.c` | 69.7 | 2923/4195 | 78.9 |
