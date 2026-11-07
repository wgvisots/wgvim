// wgvim: libFuzzer harness for the Tree-sitter runtime and one bundled parser
// (test/fuzz/README.md).
//
// Models what wgvim does with a file it opens: parse it (UTF-8, read in chunks that end at line
// ends, as the buffer reader in src/nvim/lua/treesitter.c does), walk the tree with the node
// calls the Lua API makes, run the language's own queries from runtime/queries over it, then
// apply an edit and reparse incrementally (ts_tree_edit, old tree, changed ranges, queries
// again), and finally parse only some ranges of the text, as for an injected language.
//
// Built once per language: TS_LANG_FN is the parser's entry point (tree_sitter_c, ...), and
// TS_QUERY_DIR the language's directory under runtime/queries (with "; inherits:" followed one
// level, as vim.treesitter.query does). With $TS_FUZZ_NO_QUERIES set, no queries are run: much
// faster, for the parser and its external scanner alone.
//
// Input: a 6-byte header, then the text.
//   [0]     chunking: 0 = by line, at most 256 bytes at a time (as wgvim), n = n-byte chunks
//   [1..2]  edit start (little endian, modulo the text length + 1)
//   [3]     bytes deleted at the edit
//   [4]     bytes inserted at the edit (taken from the start of the text)
//   [5]     included ranges for the last parse: low 2 bits = count (0-3), the rest a seed

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

#ifndef TS_LANG_FN
# error "define TS_LANG_FN"
#endif
#ifndef TS_QUERY_DIR
# error "define TS_QUERY_DIR"
#endif

const TSLanguage *TS_LANG_FN(void);

#define MAX_TEXT 65536
#define MAX_QUERIES 8

static TSParser *parser;
static TSQuery *queries[MAX_QUERIES];
static int nqueries;
static TSQueryCursor *qcursor;

static char *read_file(const char *path, size_t *len)
{
  FILE *f = fopen(path, "rb");
  if (f == NULL) {
    return NULL;
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc((size_t)n + 1);
  size_t got = fread(buf, 1, (size_t)n, f);
  fclose(f);
  buf[got] = '\0';
  *len = got;
  return buf;
}

/// Reads query file `name` of directory `dir`, with the files of a "; inherits: x,y" first line
/// in front (sibling directories of `dir`).
static char *read_query(const char *dir, const char *name, size_t *len)
{
  char path[4096];
  snprintf(path, sizeof(path), "%s/%s", dir, name);
  char *own = read_file(path, len);
  if (own == NULL || strncmp(own, "; inherits:", 11) != 0) {
    return own;
  }
  char *eol = strchr(own, '\n');
  char list[256] = "";
  size_t l = eol ? (size_t)(eol - own) - 11 : strlen(own) - 11;
  if (l >= sizeof(list)) {
    l = sizeof(list) - 1;
  }
  memcpy(list, own + 11, l);
  list[l] = '\0';
  char *all = calloc(1, 1);
  size_t all_len = 0;
  for (char *tok = strtok(list, ", \t\r"); tok != NULL; tok = strtok(NULL, ", \t\r")) {
    if (tok[0] == '(') {
      continue;  // "(optional)" markers
    }
    snprintf(path, sizeof(path), "%s/../%s/%s", dir, tok, name);
    size_t n;
    char *base = read_file(path, &n);
    if (base != NULL) {
      all = realloc(all, all_len + n + 2);
      memcpy(all + all_len, base, n);
      all_len += n;
      all[all_len++] = '\n';
      all[all_len] = '\0';
      free(base);
    }
  }
  all = realloc(all, all_len + *len + 1);
  memcpy(all + all_len, own, *len + 1);
  *len += all_len;
  free(own);
  return all;
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
  (void)argc;
  (void)argv;
  parser = ts_parser_new();
  ts_parser_set_language(parser, TS_LANG_FN());
  qcursor = ts_query_cursor_new();
  if (getenv("TS_FUZZ_NO_QUERIES") != NULL) {
    // Parse-only mode: several times faster, for the parser and its external scanner.
    fprintf(stderr, "treesitter_fuzzer: parse only (TS_FUZZ_NO_QUERIES)\n");
    return 0;
  }
  static const char *const names[] = {
    "highlights.scm", "injections.scm", "folds.scm", "indents.scm", "locals.scm",
  };
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
    size_t len;
    char *src = read_query(TS_QUERY_DIR, names[i], &len);
    if (src == NULL) {
      continue;
    }
    uint32_t off;
    TSQueryError err;
    TSQuery *q = ts_query_new(TS_LANG_FN(), src, (uint32_t)len, &off, &err);
    if (q == NULL) {
      // A query that does not compile against this grammar version is a finding of its own
      // (the editor would show the error); report it once and fuzz without it.
      fprintf(stderr, "treesitter_fuzzer: %s/%s does not compile (error %d at byte %u)\n",
              TS_QUERY_DIR, names[i], (int)err, off);
    } else if (nqueries < MAX_QUERIES) {
      queries[nqueries++] = q;
    }
    free(src);
  }
  fprintf(stderr, "treesitter_fuzzer: %d queries from %s\n", nqueries, TS_QUERY_DIR);
  return 0;
}

typedef struct {
  const char *text;
  uint32_t len;
  uint8_t chunk;
} Source;

/// TSInput.read: like wgvim's buffer reader (input_cb() in src/nvim/lua/treesitter.c), return
/// the rest of the line holding `byte`, at most 256 bytes, with its newline when it fits; or a
/// fixed-size chunk.
static const char *read_input(void *payload, uint32_t byte, TSPoint pos, uint32_t *bytes_read)
{
  (void)pos;
  Source *s = payload;
  if (byte >= s->len) {
    *bytes_read = 0;
    return "";
  }
  uint32_t n = s->len - byte;
  if (s->chunk == 0) {
    const char *nl = memchr(s->text + byte, '\n', n);
    uint32_t line = nl != NULL ? (uint32_t)(nl - (s->text + byte)) : n;
    n = line < 256 ? line + (nl != NULL) : 256;
  } else if (n > s->chunk) {
    n = s->chunk;
  }
  *bytes_read = n;
  return s->text + byte;
}

static TSTree *parse(const char *text, uint32_t len, uint8_t chunk, const TSTree *old)
{
  Source s = { text, len, chunk };
  TSInput in = { .payload = &s, .read = read_input, .encoding = TSInputEncodingUTF8 };
  return ts_parser_parse(parser, old, in);
}

static TSPoint point_at(const char *text, uint32_t byte)
{
  TSPoint p = { 0, 0 };
  for (uint32_t i = 0; i < byte; i++) {
    if (text[i] == '\n') {
      p.row++;
      p.column = 0;
    } else {
      p.column++;
    }
  }
  return p;
}

/// Visits every node with the calls vim.treesitter's TSNode methods make.
static void walk(TSTree *tree, uint32_t len)
{
  TSNode root = ts_tree_root_node(tree);
  TSTreeCursor c = ts_tree_cursor_new(root);
  uint32_t visited = 0;
  volatile uintptr_t sink = 0;
  for (;;) {
    TSNode n = ts_tree_cursor_current_node(&c);
    sink += (uintptr_t)ts_node_type(n) + ts_node_symbol(n) + ts_node_is_named(n)
            + ts_node_has_error(n) + ts_node_is_missing(n) + ts_node_start_byte(n)
            + ts_node_end_point(n).row + ts_node_child_count(n) + ts_node_named_child_count(n)
            + ts_node_grammar_symbol(n) + ts_node_descendant_count(n);
    const char *field = ts_tree_cursor_current_field_name(&c);
    if (field != NULL) {
      sink += (uintptr_t)field[0];
    }
    if (++visited % 16 == 0) {  // parent walks are O(depth): sample them
      TSNode p = ts_node_parent(n);
      sink += ts_node_is_null(p);
      TSNode nx = ts_node_next_named_sibling(n);
      sink += ts_node_is_null(nx);
    }
    if (ts_tree_cursor_goto_first_child(&c)) {
      continue;
    }
    while (!ts_tree_cursor_goto_next_sibling(&c)) {
      if (!ts_tree_cursor_goto_parent(&c)) {
        goto done;
      }
    }
  }
done:
  ts_tree_cursor_delete(&c);
  // vim.treesitter.get_node(): the node at a position.
  for (uint32_t b = 0; b <= len; b += len / 7 + 1) {
    TSNode d = ts_node_named_descendant_for_byte_range(root, b, b);
    sink += ts_node_is_null(d);
  }
  (void)sink;
}

/// Runs every query over `node`'s tree, as the highlighter (captures, in a range) and
/// folds/injections (matches) do.
static void run_queries(TSNode node, uint32_t start, uint32_t end)
{
  volatile uint32_t sink = 0;
  for (int i = 0; i < nqueries; i++) {
    ts_query_cursor_set_byte_range(qcursor, start, end);
    ts_query_cursor_exec(qcursor, queries[i], node);
    TSQueryMatch m;
    uint32_t idx;
    if (i == 0) {
      while (ts_query_cursor_next_capture(qcursor, &m, &idx)) {
        sink += m.captures[idx].index;
        uint32_t steps;
        const TSQueryPredicateStep *ps = ts_query_predicates_for_pattern(queries[i],
                                                                         m.pattern_index, &steps);
        sink += steps + (ps ? ps->type : 0);
      }
    } else {
      while (ts_query_cursor_next_match(qcursor, &m)) {
        sink += m.capture_count + m.pattern_index;
      }
    }
  }
  (void)sink;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  if (size < 6 || size - 6 > MAX_TEXT) {
    return 0;
  }
  uint8_t chunk = data[0];
  uint32_t len = (uint32_t)(size - 6);
  const char *text = (const char *)data + 6;
  uint32_t estart = (uint32_t)(data[1] | (data[2] << 8)) % (len + 1);
  uint32_t edel = data[3];
  uint32_t eins = data[4];
  uint8_t ranges = data[5];
  if (edel > len - estart) {
    edel = len - estart;
  }
  if (eins > len) {
    eins = len;
  }

  // 1. Open the file.
  TSTree *tree = parse(text, len, chunk, NULL);
  if (tree == NULL) {
    return 0;
  }
  walk(tree, len);
  run_queries(ts_tree_root_node(tree), 0, len);

  // 2. Edit it, and reparse incrementally.
  uint32_t nlen = len - edel + eins;
  char *ntext = malloc(nlen + 1);
  memcpy(ntext, text, estart);
  memcpy(ntext + estart, text, eins);
  memcpy(ntext + estart + eins, text + estart + edel, len - estart - edel);
  ntext[nlen] = '\0';
  TSInputEdit edit = {
    .start_byte = estart,
    .old_end_byte = estart + edel,
    .new_end_byte = estart + eins,
    .start_point = point_at(text, estart),
    .old_end_point = point_at(text, estart + edel),
    .new_end_point = point_at(ntext, estart + eins),
  };
  TSTree *old = ts_tree_copy(tree);
  ts_tree_edit(old, &edit);
  TSTree *ntree = parse(ntext, nlen, chunk, old);
  if (ntree != NULL) {
    uint32_t count;
    TSRange *changed = ts_tree_get_changed_ranges(old, ntree, &count);
    walk(ntree, nlen);
    for (uint32_t i = 0; i < count && i < 4; i++) {
      run_queries(ts_tree_root_node(ntree), changed[i].start_byte, changed[i].end_byte);
    }
    free(changed);
  }

  // 3. Parse only some ranges, as for a language injected into another (fenced code in
  // Markdown, Lua in Vim script, ...).
  uint32_t nr = ranges & 3;
  if (nr > 0 && nlen > 0) {
    TSRange r[3];
    uint32_t seed = ranges >> 2;
    uint32_t pos = 0;
    uint32_t got = 0;
    for (uint32_t i = 0; i < nr && pos < nlen; i++) {
      uint32_t a = pos + (seed * 7 + i * 13) % (nlen - pos + 1);
      uint32_t b = a + (seed * 3 + i * 31 + 1) % (nlen - a + 1);
      r[got] = (TSRange){ .start_byte = a, .end_byte = b, .start_point = point_at(ntext, a),
                          .end_point = point_at(ntext, b) };
      got++;
      pos = b + 1;
    }
    if (got > 0 && ts_parser_set_included_ranges(parser, r, got)) {
      TSTree *t3 = parse(ntext, nlen, chunk, NULL);
      if (t3 != NULL) {
        walk(t3, nlen);
        run_queries(ts_tree_root_node(t3), 0, nlen);
        ts_tree_delete(t3);
      }
    }
    ts_parser_set_included_ranges(parser, NULL, 0);
  }

  if (ntree != NULL) {
    ts_tree_delete(ntree);
  }
  ts_tree_delete(old);
  ts_tree_delete(tree);
  free(ntext);
  return 0;
}
