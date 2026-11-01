// wgvim: libFuzzer harness for terminal input parsing (src/nvim/tui/termkey).
//
// Feeds arbitrary bytes, as if typed or sent by the terminal emulator wgvim runs in, through
// termkey configured the way tui/input.c does (UTF-8, keep C0, Del->Backspace, built-in xterm
// terminfo), in chunks to exercise partial-sequence handling. Every decoded key is formatted and
// interpreted with the same helpers the TUI uses (mouse, position, mode report, CSI, OSC/DCS/APC).
//
// Build: see test/fuzz/README.md (cmake -D WGVIM_FUZZ=ON with clang).

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "nvim/tui/terminfo.h"
#include "nvim/tui/termkey/driver-csi.h"
#include "nvim/tui/termkey/termkey.h"
#include "nvim/tui/termkey/termkey_defs.h"

static void consume_key(TermKey *tk, TermKeyKey *key)
{
  char buf[128];
  termkey_strfkey(tk, buf, sizeof(buf), key, TERMKEY_FORMAT_VIM);
  termkey_strfkey(tk, buf, sizeof(buf), key,
                  TERMKEY_FORMAT_LONGMOD | TERMKEY_FORMAT_MOUSE_POS | TERMKEY_FORMAT_LOWERSPACE);

  switch (key->type) {
  case TERMKEY_TYPE_MOUSE: {
    TermKeyMouseEvent ev;
    int button, line, col;
    termkey_interpret_mouse(tk, key, &ev, &button, &line, &col);
    break;
  }
  case TERMKEY_TYPE_POSITION: {
    int line, col;
    termkey_interpret_position(tk, key, &line, &col);
    break;
  }
  case TERMKEY_TYPE_MODEREPORT: {
    int initial, mode, value;
    termkey_interpret_modereport(tk, key, &initial, &mode, &value);
    break;
  }
  case TERMKEY_TYPE_UNKNOWN_CSI: {
    TermKeyCsiParam params[16];
    size_t nparams = 16;
    unsigned cmd;
    if (termkey_interpret_csi(tk, key, params, &nparams, &cmd) == TERMKEY_RES_KEY) {
      for (size_t i = 0; i < nparams; i++) {
        int arg;
        int sub[8];
        size_t nsub = 8;
        termkey_interpret_csi_param(params[i], &arg, sub, &nsub);
      }
    }
    break;
  }
  case TERMKEY_TYPE_DCS:
  case TERMKEY_TYPE_OSC:
  case TERMKEY_TYPE_APC: {
    const char *str;
    if (termkey_interpret_string(tk, key, &str) == TERMKEY_RES_KEY) {
      volatile size_t n = strlen(str);
      (void)n;
    }
    break;
  }
  default:
    break;
  }
}

static void drain(TermKey *tk, bool force)
{
  TermKeyKey key;
  TermKeyResult res;
  // Bounded, so a parser that returns KEY forever cannot hang the fuzzer (it would be a bug,
  // but a timeout is a clearer report than an infinite loop).
  for (int i = 0; i < 100000; i++) {
    res = force ? termkey_getkey_force(tk, &key) : termkey_getkey(tk, &key);
    if (res != TERMKEY_RES_KEY) {
      break;
    }
    consume_key(tk, &key);
  }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 2) {
    return 0;
  }
  uint8_t flags = data[0];
  size_t chunk = 1 + data[1] % 64;
  data += 2;
  size -= 2;

  char *termname = NULL;
  const TerminfoEntry *ti = terminfo_from_builtin((flags & 1) ? "xterm-256color" : "tmux-256color",
                                                  &termname);

  int tkflags = TERMKEY_FLAG_UTF8 | TERMKEY_FLAG_NOSTART | TERMKEY_FLAG_KEEPC0;
  if (flags & 2) {
    tkflags = TERMKEY_FLAG_RAW | TERMKEY_FLAG_NOSTART;
  }
  TermKey *tk = termkey_new_abstract((TerminfoEntry *)ti, tkflags);
  if (tk == NULL) {
    return 0;
  }
  termkey_set_buffer_size(tk, 0xfff);  // tui/input.c uses INPUT_BUFFER_SIZE (0xfff)
  termkey_start(tk);
  termkey_set_canonflags(tk, termkey_get_canonflags(tk) | TERMKEY_CANON_DELBS
                         | ((flags & 4) ? TERMKEY_CANON_SPACESYMBOL : 0));

  // Push the input in chunks, draining after each one like the TUI's read callback does.
  size_t off = 0;
  while (off < size) {
    size_t n = size - off < chunk ? size - off : chunk;
    size_t pushed = termkey_push_bytes(tk, (const char *)data + off, n);
    drain(tk, false);
    if (pushed == 0) {
      // Buffer full and nothing consumable: what the TUI does on timeout.
      drain(tk, true);
      pushed = termkey_push_bytes(tk, (const char *)data + off, n);
      if (pushed == 0) {
        break;
      }
    }
    off += pushed;
  }
  // ESC timeout: force out anything left.
  drain(tk, true);

  termkey_destroy(tk);
  return 0;
}
