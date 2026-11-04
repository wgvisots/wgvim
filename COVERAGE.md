# wgvim functional-test coverage

Generated 2026-11-03 from commit 6afb9c8 (the sandbox, the build-tree runtime and the SELinux changes) with `cmake -D CMAKE_BUILD_TYPE=Debug -D ENABLE_GCOV=ON`, running the functional suite only (`functionaltest`: 10,035 passed, 115 skipped, 23 failed — 22 window/tab-line screen tests that fail only in Debug builds, and `man_spec`, which needs a real `man`). Skipped tests include the ~54 that need `sockconnect()`, `--remote` or `--server`, which wgvim removed. The sandbox tests run wgvim with the sandbox on; in coverage builds they allow `build/src` so the `.gcda` files can be written (`src/nvim/os/landlock.c`: 82.8% of lines). Regenerate with `scripts/coverage-summary.py <build-dir> .`. Covers the editor's own C code in `src/`; LuaJIT, libuv and other dependencies are not instrumented. For comparison, functional + old-style suites together covered 92.4% of lines (2026-11-01).

Source: 207 .gcda files, 239 source files under `src/`.

| | Covered | Total | % |
|---|---:|---:|---:|
| Lines | 134300 | 170868 | 78.6 |
| Functions | 7810 | 8607 | 90.7 |

## By directory

| Directory | Lines % | Lines (hit/total) | Functions % |
|---|---:|---:|---:|
| `src/cjson` | 75.8 | 798/1053 | 84.8 |
| `src/klib` | 0.0 | 0/3 | 0.0 |
| `src/lpeg` | 86.3 | 1696/1965 | 93.0 |
| `src/mpack` | 81.7 | 1243/1521 | 87.6 |
| `src/nvim` | 77.7 | 99266/127780 | 90.6 |
| `src/nvim/api` | 94.4 | 4809/5096 | 94.9 |
| `src/nvim/api/private` | 95.4 | 648/679 | 98.3 |
| `src/nvim/eval` | 75.6 | 10574/13984 | 86.9 |
| `src/nvim/event` | 94.0 | 934/994 | 95.7 |
| `src/nvim/lib` | 100.0 | 12/12 | 0.0 |
| `src/nvim/lua` | 90.1 | 3427/3804 | 93.1 |
| `src/nvim/msgpack_rpc` | 87.6 | 1033/1179 | 96.3 |
| `src/nvim/os` | 75.9 | 2324/3063 | 90.1 |
| `src/nvim/tui` | 87.2 | 2080/2384 | 99.2 |
| `src/nvim/tui/termkey` | 68.7 | 947/1379 | 89.2 |
| `src/nvim/viml/parser` | 93.4 | 1253/1342 | 83.3 |
| `src/nvim/vterm` | 65.7 | 2161/3289 | 92.5 |
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
| `src/nvim/vterm/state.c` | 55.9 | 856/1530 | 87.2 |
| `src/mpack/conv.c` | 56.9 | 120/211 | 69.6 |
| `src/nvim/spell.c` | 57.5 | 1032/1794 | 72.2 |
| `src/nvim/spellsuggest.c` | 57.5 | 984/1710 | 69.2 |
| `src/nvim/menu.c` | 57.8 | 603/1043 | 79.1 |
| `src/nvim/sign.c` | 58.2 | 501/861 | 74.0 |
| `src/nvim/tui/termkey/termkey.c` | 60.6 | 360/594 | 85.7 |
| `src/nvim/vterm/pen.c` | 62.1 | 247/398 | 100.0 |
| `src/nvim/cmdhist.c` | 62.6 | 236/377 | 80.0 |
| `src/nvim/profile.c` | 63.8 | 292/458 | 81.6 |
| `src/nvim/arglist.c` | 64.7 | 400/618 | 75.0 |
| `src/nvim/regexp.c` | 64.8 | 4492/6929 | 91.9 |
| `src/nvim/strings.c` | 64.8 | 1051/1621 | 81.9 |
| `src/nvim/quickfix.c` | 65.0 | 2430/3737 | 77.4 |
| `src/nvim/ex_eval.c` | 65.9 | 581/881 | 93.2 |
| `src/nvim/cmdexpand.c` | 66.7 | 1505/2256 | 74.2 |
| `src/nvim/tui/terminfo.c` | 68.3 | 293/429 | 100.0 |
| `src/nvim/os/shell.c` | 68.7 | 431/627 | 87.5 |
| `src/nvim/eval/funcs.c` | 69.7 | 2901/4164 | 78.9 |

