// wgvim: libFuzzer harness for the built-in terminal emulator (src/nvim/vterm).
//
// Feeds arbitrary bytes, as if printed by a program running in :terminal, through the same
// configuration terminal.c uses (UTF-8, altscreen, reflow, scrollback callbacks, OSC 52
// selection callbacks, unrecognised-sequence fallbacks), with a resize and keyboard/mouse
// input part-way through. Every screen cell is read back at the end.
//
// Build: see test/fuzz/README.md (cmake -D WGVIM_FUZZ=ON with clang).

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "nvim/option_vars.h"
#include "nvim/vterm/keyboard.h"
#include "nvim/vterm/mouse.h"
#include "nvim/vterm/parser.h"
#include "nvim/vterm/screen.h"
#include "nvim/vterm/state.h"
#include "nvim/vterm/vterm.h"
#include "nvim/vterm/vterm_keycodes_defs.h"

#define SB_MAX 64
#define SELBUF_SIZE 1024

typedef struct {
  int sb_count;
  int sb_cols[SB_MAX];
  VTermScreenCell sb[SB_MAX][256];
  size_t output_bytes;
  size_t selection_bytes;
} FuzzState;

static int cb_damage(VTermRect rect, void *user)
{
  (void)rect; (void)user;
  return 1;
}

static int cb_moverect(VTermRect dest, VTermRect src, void *user)
{
  (void)dest; (void)src; (void)user;
  return 1;
}

static int cb_movecursor(VTermPos pos, VTermPos oldpos, int visible, void *user)
{
  (void)pos; (void)oldpos; (void)visible; (void)user;
  return 1;
}

static int cb_settermprop(VTermProp prop, VTermValue *val, void *user)
{
  (void)user;
  // Touch string values like terminal.c does (title, icon name).
  if (prop == VTERM_PROP_TITLE || prop == VTERM_PROP_ICONNAME) {
    volatile size_t n = 0;
    for (size_t i = 0; i < val->string.len; i++) {
      n += (unsigned char)val->string.str[i];
    }
  }
  return 1;
}

static int cb_bell(void *user)
{
  (void)user;
  return 1;
}

static int cb_resize(int rows, int cols, void *user)
{
  (void)rows; (void)cols; (void)user;
  return 1;
}

static int cb_theme(bool *dark, void *user)
{
  (void)user;
  *dark = true;
  return 1;
}

// Scrollback, like terminal.c's: keep pushed lines and give them back on popline. This is the
// path where Vim had CVE-2026-28420 (combining characters in pushed lines).
static int cb_sb_pushline(int cols, const VTermScreenCell *cells, void *user)
{
  FuzzState *st = user;
  if (cols > 256) {
    cols = 256;
  }
  int slot = st->sb_count < SB_MAX ? st->sb_count++ : SB_MAX - 1;
  memcpy(st->sb[slot], cells, (size_t)cols * sizeof(*cells));
  st->sb_cols[slot] = cols;
  return 1;
}

static int cb_sb_popline(int cols, VTermScreenCell *cells, void *user)
{
  FuzzState *st = user;
  if (st->sb_count == 0) {
    return 0;
  }
  int slot = --st->sb_count;
  int n = st->sb_cols[slot] < cols ? st->sb_cols[slot] : cols;
  memcpy(cells, st->sb[slot], (size_t)n * sizeof(*cells));
  for (int i = n; i < cols; i++) {
    memset(&cells[i], 0, sizeof(cells[i]));
    cells[i].width = 1;
  }
  return 1;
}

static int cb_sb_clear(void *user)
{
  ((FuzzState *)user)->sb_count = 0;
  return 1;
}

static const VTermScreenCallbacks screen_callbacks = {
  .damage = cb_damage,
  .moverect = cb_moverect,
  .movecursor = cb_movecursor,
  .settermprop = cb_settermprop,
  .bell = cb_bell,
  .resize = cb_resize,
  .theme = cb_theme,
  .sb_pushline = cb_sb_pushline,
  .sb_popline = cb_sb_popline,
  .sb_clear = cb_sb_clear,
};

static int fb_frag(VTermStringFragment frag, void *user)
{
  FuzzState *st = user;
  st->selection_bytes += frag.len;
  return 1;
}

static int fb_osc(int command, VTermStringFragment frag, void *user)
{
  (void)command;
  return fb_frag(frag, user);
}

static int fb_dcs(const char *command, size_t commandlen, VTermStringFragment frag, void *user)
{
  (void)command; (void)commandlen;
  return fb_frag(frag, user);
}

static const VTermStateFallbacks fallbacks = {
  .osc = fb_osc,
  .dcs = fb_dcs,
  .apc = fb_frag,
  .pm = fb_frag,
  .sos = fb_frag,
};

static int sel_set(VTermSelectionMask mask, VTermStringFragment frag, void *user)
{
  (void)mask;
  return fb_frag(frag, user);
}

static const VTermSelectionCallbacks selection_callbacks = {
  .set = sel_set,
  .query = NULL,  // terminal.c does not support clipboard queries either
};

static void output_cb(const char *s, size_t len, void *user)
{
  FuzzState *st = user;
  volatile unsigned char sink = 0;
  for (size_t i = 0; i < len; i++) {
    sink ^= (unsigned char)s[i];
  }
  st->output_bytes += len;
}

// The emulator uses the editor's character-width code, which reads two options. The harness
// does not run the editor's option initialization, so set their defaults here.
int LLVMFuzzerInitialize(int *argc, char ***argv);
int LLVMFuzzerInitialize(int *argc, char ***argv)
{
  (void)argc; (void)argv;
  p_ambw = "single";  // 'ambiwidth'
  p_emoji = true;     // 'emoji'
  return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 4) {
    return 0;
  }
  // Header: rows, cols, flags, split point; the rest is terminal output.
  int rows = 1 + data[0] % 60;
  int cols = 1 + data[1] % 200;
  uint8_t flags = data[2];
  size_t split = size > 4 ? data[3] % (size - 4 + 1) : 0;
  data += 4;
  size -= 4;

  static FuzzState st;
  memset(&st, 0, sizeof(st));
  static char selbuf[SELBUF_SIZE];

  VTerm *vt = vterm_new(rows, cols);
  vterm_set_utf8(vt, !(flags & 1));
  vterm_output_set_callback(vt, output_cb, &st);

  VTermScreen *vts = vterm_obtain_screen(vt);
  vterm_screen_enable_altscreen(vts, true);
  vterm_screen_enable_reflow(vts, !(flags & 2));
  vterm_screen_set_callbacks(vts, &screen_callbacks, &st);
  vterm_screen_set_unrecognised_fallbacks(vts, &fallbacks, &st);
  vterm_screen_set_damage_merge(vts, (flags & 4) ? VTERM_DAMAGE_SCROLL : VTERM_DAMAGE_CELL);
  vterm_screen_reset(vts, 1);

  VTermState *state = vterm_obtain_state(vt);
  vterm_state_set_selection_callbacks(state, &selection_callbacks, &st, selbuf, sizeof(selbuf));

  // First part of the output.
  vterm_input_write(vt, (const char *)data, split);
  vterm_screen_flush_damage(vts);

  // Resize (exercises reflow and scrollback pop/push), then some user input.
  if (flags & 8) {
    vterm_set_size(vt, 1 + (rows * 7 + 3) % 60, 1 + (cols * 5 + 1) % 200);
  }
  if (flags & 16) {
    vterm_keyboard_unichar(vt, 'x', VTERM_MOD_CTRL);
    vterm_keyboard_key(vt, VTERM_KEY_UP, VTERM_MOD_SHIFT);
    vterm_mouse_move(vt, 0, 0, VTERM_MOD_NONE);
    vterm_mouse_button(vt, 1, true, VTERM_MOD_NONE);
    vterm_mouse_button(vt, 1, false, VTERM_MOD_NONE);
  }
  if (flags & 32) {
    vterm_state_focus_in(state);
    vterm_state_focus_out(state);
  }

  // Rest of the output.
  vterm_input_write(vt, (const char *)data + split, size - split);
  vterm_screen_flush_damage(vts);

  // Read back every cell.
  int r, c;
  vterm_get_size(vt, &r, &c);
  VTermScreenCell cell;
  volatile uint32_t sink = 0;
  for (int row = 0; row < r; row++) {
    for (int col = 0; col < c; col++) {
      if (vterm_screen_get_cell(vts, (VTermPos){ .row = row, .col = col }, &cell)) {
        sink ^= (uint32_t)cell.schar ^ (uint32_t)cell.width;
      }
    }
    (void)vterm_state_get_lineinfo(state, row);
  }

  vterm_free(vt);
  return 0;
}
