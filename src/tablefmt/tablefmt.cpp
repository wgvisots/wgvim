// tablefmt -- a post-processor for clang-format that turns runs of similar
// lines into tables.
//
//   clang-format file.cpp | tablefmt
//
// Rule (applied the same way everywhere, so the result is predictable):
//   Consecutive lines with the same indentation and the same "shape" form a
//   table.  Every structural position the lines share becomes a column:
//   brackets, commas, semicolons, spaced operators, and each word.  Where the
//   lines differ (e.g. different contents inside a bracket), that span becomes
//   one opaque cell.  Cells are left-aligned and padded on the right, so
//   closing brackets, commas, and semicolons line up too.
//
// tablefmt only ever changes whitespace.  Each rewritten line is re-lexed and
// compared token-for-token with the original; on any mismatch the line is kept.
//
// SPDX-License-Identifier: MIT

#include <algorithm>
#include <cctype>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <optional>
#include <span>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

// ---------------------------------------------------------------- options --

struct Options {
    int                              columnLimit    = 0;     // 0 = no limit
    bool                             hugCommas      = false; // "1,   2" instead of "1  , 2"
    bool                             attachBraces   = true;  // "struct X{" / "f(){"
    bool                             acrossComments = true;  // comment-only lines don't break a table
    bool                             inPlace        = false;
    std::vector<std::pair<int, int>> ranges;                 // 1-based, inclusive; empty = all
};

// ------------------------------------------------------------------ lexer --

enum class TK { Ident, Number, String, Char, Punct, Comment };

struct Tok {
    TK          kind = TK::Punct;
    std::string text;
    int         gap  = 0; // whitespace before this token
};

struct LexState {
    bool        inBlockComment = false;
    bool        inRawString    = false;
    std::string rawEnd;            // )delim"
    bool        continued      = false; // previous line ended with a backslash
    bool        formatOff      = false;
};

enum class LineKind { Blank, CommentOnly, Code, Opaque };

bool isIdentStart(char c) { return std::isalpha(static_cast<unsigned char>(c)) || c == '_' || (c & 0x80); }
bool isIdentChar (char c) { return std::isalnum(static_cast<unsigned char>(c)) || c == '_' || (c & 0x80); }

bool isLiteralPrefix(std::string_view s) {
    return s == "L" || s == "u" || s == "U" || s == "u8" || s == "R" || s == "LR" || s == "uR" || s == "UR" ||
           s == "u8R";
}

const char* const kPunct3[] = {"<=>", ">>=", "<<=", "->*", "..."};
const char* const kPunct2[] = {"::", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "+=",
                               "-=", "*=", "/=", "%=", "&=", "|=", "^=", ".*", "##"};

struct LexResult {
    LineKind         kind = LineKind::Opaque;
    std::string      indent;
    std::vector<Tok> toks;
    std::string      comment; // trailing comment, if any
    int              commentGap = 0;
};

bool mentions(std::string_view text, std::string_view what) { return text.find(what) != std::string_view::npos; }

void checkFormatMarkers(std::string_view comment, LexState& st, bool& opaque) {
    if (mentions(comment, "clang-format off") || mentions(comment, "tablefmt off")) { st.formatOff = true;  opaque = true; }
    if (mentions(comment, "clang-format on")  || mentions(comment, "tablefmt on" )) { st.formatOff = false; opaque = true; }
}

// Lex one line.  `st` carries multi-line constructs (block comments, raw
// strings, macro continuations) from line to line.  Lines touched by those
// are reported as Opaque and never modified.
LexResult lexLine(const std::string& s, LexState& st) {
    LexResult r;
    bool      opaque = st.formatOff || st.continued;
    size_t    i = 0, n = s.size();

    if (st.inBlockComment) {
        opaque     = true;
        size_t p   = s.find("*/");
        checkFormatMarkers(s.substr(0, p == std::string::npos ? n : p), st, opaque);
        if (p == std::string::npos) { st.continued = false; return r; }
        st.inBlockComment = false;
        i                 = p + 2;
    } else if (st.inRawString) {
        opaque   = true;
        size_t p = s.find(st.rawEnd);
        if (p == std::string::npos) { st.continued = false; return r; }
        st.inRawString = false;
        i              = p + st.rawEnd.size();
    }

    size_t firstNonWs = s.find_first_not_of(" \t");
    if (firstNonWs == std::string::npos) {
        st.continued = false;
        r.kind       = opaque ? LineKind::Opaque : LineKind::Blank;
        return r;
    }
    r.indent = s.substr(0, firstNonWs);
    if (i == 0 && s[firstNonWs] == '#') opaque = true; // preprocessor

    int  gap          = 0;
    bool endsWithBsl  = false;
    auto push = [&](TK k, std::string text) { r.toks.push_back({k, std::move(text), gap}); gap = 0; };

    auto lexQuoted = [&](size_t start, size_t q) { // s[q] is ' or "
        char   quote = s[q];
        size_t j     = q + 1;
        while (j < n && s[j] != quote) j += (s[j] == '\\') ? 2 : 1;
        if (j >= n) { opaque = true; j = n; } else { ++j; }
        // user-defined literal suffix sticks to the literal
        while (j < n && isIdentChar(s[j])) ++j;
        push(quote == '"' ? TK::String : TK::Char, s.substr(start, j - start));
        i = j;
    };

    while (i < n) {
        char c = s[i];
        if (c == ' ' || c == '\t') { ++gap; ++i; continue; }
        if (c == '\\' && s.find_first_not_of(" \t", i + 1) == std::string::npos) { endsWithBsl = true; opaque = true; break; }
        if (c == '/' && i + 1 < n && s[i + 1] == '/') {
            r.comment    = s.substr(i, s.find_last_not_of(" \t") + 1 - i);
            r.commentGap = gap;
            checkFormatMarkers(r.comment, st, opaque);
            if (s.back() == '\\') { endsWithBsl = true; opaque = true; }
            break;
        }
        if (c == '/' && i + 1 < n && s[i + 1] == '*') {
            size_t p = s.find("*/", i + 2);
            if (p == std::string::npos) {
                checkFormatMarkers(s.substr(i), st, opaque);
                st.inBlockComment = true;
                opaque            = true;
                break;
            }
            std::string text = s.substr(i, p + 2 - i);
            checkFormatMarkers(text, st, opaque);
            if (s.find_first_not_of(" \t", p + 2) == std::string::npos) {
                r.comment    = text;
                r.commentGap = gap;
                break;
            }
            push(TK::Comment, text);
            i = p + 2;
            continue;
        }
        if (isIdentStart(c)) {
            size_t j = i;
            while (j < n && isIdentChar(s[j])) ++j;
            std::string id = s.substr(i, j - i);
            if (j < n && (s[j] == '"' || s[j] == '\'') && isLiteralPrefix(id)) {
                if (id.back() == 'R' && s[j] == '"') { // raw string
                    size_t open = s.find('(', j + 1);
                    if (open == std::string::npos) { opaque = true; push(TK::String, s.substr(i)); break; }
                    std::string end = ")" + s.substr(j + 1, open - j - 1) + "\"";
                    size_t      p   = s.find(end, open + 1);
                    if (p == std::string::npos) {
                        st.inRawString = true;
                        st.rawEnd      = end;
                        opaque         = true;
                        break;
                    }
                    size_t k = p + end.size();
                    while (k < n && isIdentChar(s[k])) ++k;
                    push(TK::String, s.substr(i, k - i));
                    i = k;
                    continue;
                }
                lexQuoted(i, j);
                continue;
            }
            push(TK::Ident, id);
            i = j;
            continue;
        }
        if (std::isdigit(static_cast<unsigned char>(c)) ||
            (c == '.' && i + 1 < n && std::isdigit(static_cast<unsigned char>(s[i + 1])))) {
            size_t j = i;
            while (j < n) {
                char d = s[j];
                if ((d == 'e' || d == 'E' || d == 'p' || d == 'P') && j + 1 < n && (s[j + 1] == '+' || s[j + 1] == '-')) j += 2;
                else if (isIdentChar(d) || d == '.') ++j;
                else if (d == '\'' && j + 1 < n && isIdentChar(s[j + 1])) j += 2; // digit separator
                else break;
            }
            push(TK::Number, s.substr(i, j - i));
            i = j;
            continue;
        }
        if (c == '"' || c == '\'') { lexQuoted(i, i); continue; }

        size_t len = 1;
        for (const char* p : kPunct3) if (s.compare(i, 3, p) == 0) { len = 3; break; }
        if (len == 1) for (const char* p : kPunct2) if (s.compare(i, 2, p) == 0) { len = 2; break; }
        push(TK::Punct, s.substr(i, len));
        i += len;
    }

    st.continued = endsWithBsl;
    if (!r.toks.empty()) r.toks.front().gap = 0;
    if (opaque) r.kind = LineKind::Opaque;
    else if (r.toks.empty()) r.kind = LineKind::CommentOnly;
    else r.kind = LineKind::Code;
    return r;
}

bool isP(const Tok& t, std::string_view s) { return t.kind == TK::Punct && t.text == s; }
bool isOpen (const Tok& t) { return isP(t, "(") || isP(t, "[") || isP(t, "{"); }
bool isClose(const Tok& t) { return isP(t, ")") || isP(t, "]") || isP(t, "}"); }
bool isSep  (const Tok& t) { return isP(t, ",") || isP(t, ";"); }

// Fold "name<...>" into one token so commas inside template arguments are not
// treated as separators.  After clang-format, a template '<' hugs its name;
// a comparison '<' has spaces around it.
void glueTemplates(std::vector<Tok>& t) {
    for (size_t i = 0; i + 1 < t.size(); ++i) {
        if (t[i].kind != TK::Ident || !isP(t[i + 1], "<") || t[i + 1].gap != 0) continue;
        int               angle = 0;
        std::vector<char> stack;
        size_t            end   = 0;
        for (size_t k = i + 1; k < t.size(); ++k) {
            const Tok& x = t[k];
            if (x.kind != TK::Punct) continue;
            const std::string& p = x.text;
            if (p == ";" || p == ">=" || p == ">>=") break;
            if (stack.empty() && (p == "&&" || p == "||") && x.gap > 0 && k + 1 < t.size() && t[k + 1].gap > 0) break;
            if (p == "(" || p == "[" || p == "{") { stack.push_back(p[0]); continue; }
            if (p == ")" || p == "]" || p == "}") {
                char want = p == ")" ? '(' : p == "]" ? '[' : '{';
                if (stack.empty() || stack.back() != want) break;
                stack.pop_back();
                continue;
            }
            if (!stack.empty()) continue;
            if (p == "<") ++angle;
            else if (p == ">") --angle;
            else if (p == ">>") angle -= 2;
            if (angle < 0) break;
            if (angle == 0) { end = k; break; }
        }
        if (end == 0) continue;
        for (size_t k = i + 1; k <= end; ++k) {
            t[i].text.append(static_cast<size_t>(t[k].gap), ' ');
            t[i].text += t[k].text;
        }
        t.erase(t.begin() + static_cast<long>(i) + 1, t.begin() + static_cast<long>(end) + 1);
    }
}

// Words after which clang-format keeps a space before '(' -- used so that
// "return (x);" never groups with "foo(x);".
bool isSpaceKeyword(std::string_view w) {
    static const char* const kw[] = {"if",       "for",   "while", "switch", "catch",  "return", "co_return",
                                     "co_await", "co_yield", "throw", "case", "and", "or",      "not",
                                     "delete",   "new",   "constexpr", "consteval", "requires"};
    for (const char* k : kw) if (w == k) return true;
    return false;
}

bool noAttachBefore(std::string_view w) {
    return w == "return" || w == "co_return" || w == "co_yield" || w == "throw" || w == "case";
}

// "struct X {" -> "struct X{", "f() {" -> "f(){", "else {" -> "else{".
bool attachBlockBraces(std::vector<Tok>& t) {
    bool changed = false;
    for (size_t k = 1; k < t.size(); ++k) {
        if (!isP(t[k], "{") || t[k].gap == 0) continue;
        const Tok& p  = t[k - 1];
        bool       ok = isP(p, ")") || isP(p, "]") || (p.kind == TK::Ident && !noAttachBefore(p.text)) ||
                  (p.kind == TK::String && k >= 2 && t[k - 2].text == "extern");
        if (ok) { t[k].gap = 0; changed = true; }
    }
    return changed;
}

// --------------------------------------------------------------- elements --

struct Elem {
    enum Kind { Word, Op, Group, Sep } kind = Word;
    std::string       text;     // Word/Op/Sep text, or the opening bracket
    int               gap = 0;  // whitespace before
    std::vector<Elem> kids;     // Group contents
    std::string       close;    // Group closing bracket
    int               closeGap = 0;
    bool              kwBefore = false; // Group preceded by e.g. "return "
};

std::optional<std::vector<Elem>> parseLevel(const std::vector<Tok>& t, size_t& i, const char* expectClose,
                                            int& closeGap) {
    std::vector<Elem> out;
    while (i < t.size()) {
        const Tok& k = t[i];
        if (isClose(k)) {
            if (!expectClose || k.text != expectClose) return std::nullopt;
            closeGap = k.gap;
            ++i;
            return out;
        }
        if (isOpen(k)) {
            Elem g;
            g.kind     = Elem::Group;
            g.text     = k.text;
            g.gap      = k.gap;
            g.kwBefore = !out.empty() && out.back().kind == Elem::Word && isSpaceKeyword(out.back().text);
            ++i;
            const char* ec = k.text == "(" ? ")" : k.text == "[" ? "]" : "}";
            int         cg = 0;
            auto        kids = parseLevel(t, i, ec, cg);
            if (!kids) return std::nullopt;
            g.kids     = std::move(*kids);
            g.close    = ec;
            g.closeGap = cg;
            out.push_back(std::move(g));
            continue;
        }
        if (isSep(k)) {
            Elem s;
            s.kind = Elem::Sep;
            s.text = k.text;
            s.gap  = k.gap;
            out.push_back(std::move(s));
            ++i;
            continue;
        }
        // An atom: a run of tokens with no whitespace between them.
        Elem a;
        a.gap         = k.gap;
        a.text        = k.text;
        bool allPunct = k.kind == TK::Punct;
        ++i;
        while (i < t.size() && t[i].gap == 0 && !isOpen(t[i]) && !isClose(t[i]) && !isSep(t[i])) {
            a.text += t[i].text;
            allPunct = allPunct && t[i].kind == TK::Punct;
            ++i;
        }
        a.kind = allPunct ? Elem::Op : Elem::Word;
        out.push_back(std::move(a));
    }
    if (expectClose) return std::nullopt;
    return out;
}

using Span = std::span<const Elem>;

// "case 1:", "default:", "public:" -- a word that ends a label.
bool isLabel(const Elem& e) {
    return e.kind == Elem::Word && e.text.size() > 1 && e.text.back() == ':' &&
           e.text.compare(e.text.size() - 2, 2, "::") != 0;
}
bool isRunWord(const Elem& e) { return e.kind == Elem::Word && !isLabel(e); }

bool isAssignOp(const Elem& e) {
    if (e.kind != Elem::Op) return false;
    static const char* const ops[] = {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="};
    for (const char* o : ops) if (e.text == o) return true;
    return false;
}

// Shape of a list.  Consecutive words collapse to one symbol, so
// "double a" and "const int b" have the same shape, and all assignment
// operators look alike, so "x = 1" and "y += 2" share a table.
std::string shapeOf(Span v) {
    std::string s;
    for (size_t j = 0; j < v.size(); ++j) {
        const Elem& x = v[j];
        switch (x.kind) {
        case Elem::Word:
            if (isLabel(x)) { s += "L "; break; }
            if (j > 0 && isRunWord(v[j - 1])) break;
            s += x.gap == 0 ? "Wa " : "W ";
            break;
        case Elem::Op:    s += "o" + (isAssignOp(x) ? std::string("=") : x.text) + (x.gap == 0 ? "a " : " "); break;
        case Elem::Sep:   s += x.text + " "; break;
        case Elem::Group: s += x.text + (x.kwBefore ? "k " : " "); break;
        }
    }
    return s;
}

// Plain single-line rendering of a list (used for opaque cells).  Stale
// padding before closers and separators is dropped.
std::string plain(Span v) {
    std::string s;
    for (size_t j = 0; j < v.size(); ++j) {
        const Elem& x = v[j];
        if (j > 0 && x.kind != Elem::Sep && x.gap > 0) s += ' ';
        s += x.text;
        if (x.kind == Elem::Group) {
            bool spaced = !x.kids.empty() && x.kids.front().gap > 0; // "{ return x; }" style
            if (spaced) s += ' ';
            s += plain(x.kids);
            if (spaced) s += ' ';
            s += x.close;
        }
    }
    return s;
}

// ---------------------------------------------------------------- columns --

struct Col {
    std::vector<std::string> cells;          // one per line
    std::vector<int>         obs;            // whitespace seen before each cell (-1: none)
    int                      fixedGap = -1;  // >= 0: always use exactly this gap
    bool                     hug      = false; // stick to the previous cell, pad after
    bool                     right    = false; // right-align (assignment operators)

    void add(std::string text, int gap) { cells.push_back(std::move(text)); obs.push_back(gap); }
};

int displayWidth(std::string_view s) {
    int w = 0;
    for (unsigned char c : s) if ((c & 0xC0) != 0x80) ++w;
    return w;
}

bool sameShape(const std::vector<Span>& L) {
    std::string first = shapeOf(L[0]);
    for (size_t i = 1; i < L.size(); ++i) if (shapeOf(L[i]) != first) return false;
    return true;
}

void opaqueCol(const std::vector<Span>& L, std::vector<Col>& cols) {
    Col c;
    for (const Span& s : L) c.add(plain(s), s.empty() ? -1 : s.front().gap);
    cols.push_back(std::move(c));
}

// Turn N same-shaped lists into a flat list of columns.
void flatten(const std::vector<Span>& L, std::vector<Col>& cols, const Options& o) {
    const size_t        N = L.size();
    std::vector<size_t> p(N, 0);
    while (p[0] < L[0].size()) {
        const Elem& e0 = L[0][p[0]];
        if (isRunWord(e0)) {
            std::vector<std::vector<const Elem*>> runs(N);
            for (size_t i = 0; i < N; ++i)
                while (p[i] < L[i].size() && isRunWord(L[i][p[i]])) runs[i].push_back(&L[i][p[i]++]);
            auto counts = [&](auto pred) { return std::all_of(runs.begin(), runs.end(), pred); };
            if (counts([&](auto& r) { return r.size() == runs[0].size(); })) {
                // Same number of words everywhere: one column per word.
                for (size_t j = 0; j < runs[0].size(); ++j) {
                    Col c;
                    for (auto& r : runs) c.add(r[j]->text, r[j]->gap);
                    cols.push_back(std::move(c));
                }
            } else if (counts([](auto& r) { return r.size() >= 2; })) {
                // "const int x" / "double y": the last word (the name) gets its own column.
                Col head, last;
                for (auto& r : runs) {
                    std::string h;
                    for (size_t j = 0; j + 1 < r.size(); ++j) h += (j ? " " : "") + r[j]->text;
                    head.add(h, r[0]->gap);
                    last.add(r.back()->text, r.back()->gap);
                }
                cols.push_back(std::move(head));
                cols.push_back(std::move(last));
            } else {
                // "int x" / "x": keep the words together.
                Col c;
                for (auto& r : runs) {
                    std::string h;
                    for (size_t j = 0; j < r.size(); ++j) h += (j ? " " : "") + r[j]->text;
                    c.add(h, r[0]->gap);
                }
                cols.push_back(std::move(c));
            }
            continue;
        }
        if (e0.kind != Elem::Group) { // operator, separator, or label
            Col c;
            for (size_t i = 0; i < N; ++i) { c.add(L[i][p[i]].text, L[i][p[i]].gap); ++p[i]; }
            if (e0.kind == Elem::Sep) { c.fixedGap = 0; c.hug = o.hugCommas && e0.text == ","; }
            if (isAssignOp(e0)) c.right = true;
            cols.push_back(std::move(c));
            continue;
        }
        // Group: open bracket, contents, close bracket.
        Col               open, close;
        std::vector<Span> inner;
        close.fixedGap = 0;
        for (size_t i = 0; i < N; ++i) {
            const Elem& g = L[i][p[i]];
            open.add(g.text, g.gap);
            close.add(g.close, 0);
            if (!g.kids.empty() && g.kids.front().gap > 0) close.fixedGap = 1; // "{ 1, 2 }" style
            inner.emplace_back(g.kids);
            ++p[i];
        }
        cols.push_back(std::move(open));
        if (sameShape(inner)) flatten(inner, cols, o);
        else opaqueCol(inner, cols);
        cols.push_back(std::move(close));
    }
}

// ------------------------------------------------------------------ lines --

struct Line {
    std::string                      text; // current text (no newline)
    bool                             cr = false;
    LexResult                        lex;
    std::optional<std::vector<Elem>> elems;
    size_t                           bodyEnd  = 0;  // elems minus a trailing , or ;
    long                             assignAt = -1; // index of the first top-level assignment
    std::string                      key;
};

std::string renderTokens(const Line& L) {
    std::string s = L.lex.indent;
    for (const Tok& t : L.lex.toks) { s.append(static_cast<size_t>(t.gap), ' '); s += t.text; }
    if (!L.lex.comment.empty()) { s.append(static_cast<size_t>(L.lex.commentGap), ' '); s += L.lex.comment; }
    return s;
}

std::vector<std::string> tokenTexts(const std::string& line, std::string* comment) {
    LexState st;
    auto     r = lexLine(line, st);
    std::vector<std::string> v;
    for (auto& t : r.toks) v.push_back(t.text);
    if (comment) *comment = r.comment;
    return v;
}

bool inRanges(const Options& o, size_t lineIdx) {
    if (o.ranges.empty()) return true;
    int ln = static_cast<int>(lineIdx) + 1;
    for (auto [a, b] : o.ranges) if (ln >= a && ln <= b) return true;
    return false;
}

void alignGroup(std::vector<Line>& lines, const std::vector<size_t>& members, const Options& o) {
    const size_t     N = members.size();
    std::vector<Col> cols;
    auto line = [&](size_t i) -> const Line& { return lines[members[i]]; };

    if (line(0).assignAt >= 0) {
        // [left side ... =] [right side]
        std::vector<Span> lhs, rhs;
        for (size_t i = 0; i < N; ++i) {
            const auto& e = *line(i).elems;
            size_t      a = static_cast<size_t>(line(i).assignAt);
            lhs.emplace_back(e.data(), a + 1);
            rhs.emplace_back(e.data() + a + 1, line(i).bodyEnd - a - 1);
        }
        flatten(lhs, cols, o);
        if (sameShape(rhs)) flatten(rhs, cols, o);
        else opaqueCol(rhs, cols);
    } else {
        std::vector<Span> body;
        for (size_t i = 0; i < N; ++i) body.emplace_back(line(i).elems->data(), line(i).bodyEnd);
        flatten(body, cols, o);
    }

    // Terminator (; or ,) and trailing comment get their own columns.
    Col term, comment;
    term.fixedGap = 0;
    for (size_t i = 0; i < N; ++i) {
        const Line& L = line(i);
        bool        t = L.bodyEnd < L.elems->size();
        term.add(t ? L.elems->back().text : "", -1);
        comment.add(L.lex.comment, L.lex.comment.empty() ? -1 : L.lex.commentGap);
    }
    term.hug = o.hugCommas && std::find(term.cells.begin(), term.cells.end(), ",") != term.cells.end();
    cols.push_back(std::move(term));
    cols.push_back(std::move(comment));

    std::vector<int>  width(cols.size(), 0);
    std::vector<bool> used(cols.size(), false); // any cell has text (a cell of only UTF-8
                                                // continuation bytes is 0 wide, yet not empty)
    for (size_t k = 0; k < cols.size(); ++k)
        for (auto& c : cols[k].cells) {
            width[k] = std::max(width[k], displayWidth(c));
            used[k]  = used[k] || !c.empty();
        }

    // Choose each column's gap.  The whitespace seen in the input may include
    // padding from an earlier run, so subtract the padding this layout would
    // put there; what remains is the "natural" gap.  This keeps tablefmt
    // idempotent and preserves wider gaps that clang-format chose.
    std::vector<int> gap(cols.size(), 0);
    std::vector<int> carry(N, 0); // spaces emitted since the last non-empty cell, per line
    bool             first = true;
    for (size_t k = 0; k < cols.size(); ++k) {
        if (!used[k]) continue;
        const Col& c = cols[k];
        if (c.hug) { // no gap; this column's padding goes after it
            for (size_t i = 0; i < N; ++i) carry[i] += width[k] - displayWidth(c.cells[i]);
            continue;
        }
        if (first) gap[k] = 0;
        else if (c.fixedGap >= 0) gap[k] = c.fixedGap;
        else {
            int floor = 1, g = INT_MAX;
            for (size_t i = 0; i < N; ++i) if (c.obs[i] >= 0) floor = std::min(floor, c.obs[i]);
            if (&c == &cols.back()) floor = 1; // a comment always needs a space
            for (size_t i = 0; i < N; ++i) {
                if (c.obs[i] < 0 || c.cells[i].empty()) continue;
                int lead = c.right ? width[k] - displayWidth(c.cells[i]) : 0;
                g        = std::min(g, std::max(floor, c.obs[i] - carry[i] - lead));
            }
            gap[k] = g == INT_MAX ? floor : g;
        }
        for (size_t i = 0; i < N; ++i) {
            int w = displayWidth(c.cells[i]);
            if (!c.cells[i].empty()) carry[i] = c.right ? 0 : width[k] - w;
            else carry[i] += gap[k] + width[k];
        }
        first = false;
    }

    std::vector<std::string> out(N);
    for (size_t i = 0; i < N; ++i) {
        std::string s       = line(i).lex.indent;
        int         pending = 0;
        for (size_t k = 0; k < cols.size(); ++k) {
            if (!used[k]) continue;
            const Col&         c    = cols[k];
            const std::string& cell = c.cells[i];
            int                w    = displayWidth(cell);
            if (c.hug) { s += cell; s.append(static_cast<size_t>(pending + width[k] - w), ' '); pending = 0; continue; }
            s.append(static_cast<size_t>(pending + gap[k]), ' ');
            if (c.right) { s.append(static_cast<size_t>(width[k] - w), ' '); pending = 0; }
            else pending = width[k] - w;
            s += cell;
        }
        while (!s.empty() && s.back() == ' ') s.pop_back();
        if (o.columnLimit > 0 && displayWidth(s) > o.columnLimit) return; // leave the group alone
        out[i] = std::move(s);
    }

    for (size_t i = 0; i < N; ++i) {
        Line&       L = lines[members[i]];
        std::string c1, c2;
        if (tokenTexts(L.text, &c1) != tokenTexts(out[i], &c2) || c1 != c2) {
            std::cerr << "tablefmt: internal error, left line " << members[i] + 1 << " unchanged\n";
#ifdef TABLEFMT_FUZZ
            // The safety net caught a bug in the alignment: in the strict fuzzing mode, report it.
            if (std::getenv("TABLEFMT_FUZZ_STRICT")) std::abort();
#endif
            continue;
        }
        L.text = out[i];
    }
}

std::string formatText(const std::string& input, const Options& o) {
    std::vector<Line> lines;
    for (size_t start = 0; start < input.size();) {
        size_t nl = input.find('\n', start);
        Line   L;
        L.text = input.substr(start, nl == std::string::npos ? std::string::npos : nl - start);
        if (!L.text.empty() && L.text.back() == '\r') { L.text.pop_back(); L.cr = true; }
        lines.push_back(std::move(L));
        if (nl == std::string::npos) break;
        start = nl + 1;
    }
    const bool trailingNewline = !input.empty() && input.back() == '\n';

    LexState st;
    for (size_t i = 0; i < lines.size(); ++i) {
        Line& L = lines[i];
        L.lex   = lexLine(L.text, st);
        if (L.lex.kind != LineKind::Code) continue;
        glueTemplates(L.lex.toks);
        if (o.attachBraces && inRanges(o, i) && attachBlockBraces(L.lex.toks)) L.text = renderTokens(L);
        size_t pos = 0;
        int    cg  = 0;
        L.elems    = parseLevel(L.lex.toks, pos, nullptr, cg);
        if (!L.elems || L.elems->empty()) { L.elems.reset(); continue; }
        const auto& e = *L.elems;
        L.bodyEnd     = e.size() - (e.back().kind == Elem::Sep ? 1 : 0);
        if (L.bodyEnd == 0) { L.elems.reset(); continue; }
        for (size_t k = 0; k < L.bodyEnd; ++k) if (isAssignOp(e[k])) { L.assignAt = static_cast<long>(k); break; }
        Span body(e.data(), L.bodyEnd);
        // A trailing ',' is optional (last row of an initializer list); ';' is not.
        std::string term = L.bodyEnd < e.size() && e.back().text == ";" ? ";" : "";
        L.key = L.lex.indent + "\x1f" +
                (L.assignAt >= 0 ? shapeOf(body.first(static_cast<size_t>(L.assignAt) + 1)) + "|=|" : shapeOf(body)) +
                "\x1f" + term;
    }

    for (size_t i = 0; i < lines.size();) {
        if (!lines[i].elems) { ++i; continue; }
        std::vector<size_t> members{i};
        for (size_t j = i + 1; j < lines.size(); ++j) {
            if (o.acrossComments && lines[j].lex.kind == LineKind::CommentOnly) continue;
            if (lines[j].elems && lines[j].key == lines[i].key) { members.push_back(j); continue; }
            break;
        }
        bool touched = std::any_of(members.begin(), members.end(), [&](size_t m) { return inRanges(o, m); });
        if (members.size() >= 2 && touched) alignGroup(lines, members, o);
        i = members.back() + 1;
    }

    std::string out;
    out.reserve(input.size() + input.size() / 4);
    for (size_t i = 0; i < lines.size(); ++i) {
        out += lines[i].text;
        if (lines[i].cr) out += '\r';
        if (i + 1 < lines.size() || trailingNewline) out += '\n';
    }
    return out;
}

// ------------------------------------------------------------------- main --

void usage() {
    std::cout <<
R"(usage: tablefmt [options] [file...]

Aligns runs of similar lines into tables.  Run it after clang-format:
    clang-format file.cpp | tablefmt

With no files, reads stdin and writes stdout.

options:
  -i                   edit files in place
  --lines=N:M          only touch tables that overlap lines N..M (repeatable)
  --column-limit=N     leave a table alone if aligning it would exceed N columns
  --hug-commas         "1,   2" instead of "1  , 2"
  --no-attach-braces   keep "struct X {" instead of "struct X{"
  --no-across-comments comment-only lines end a table
  -h, --help           this help
)";
}

bool readAll(std::istream& in, std::string& out) {
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return !in.bad();
}

} // namespace

// The fuzz harness (test/fuzz/tablefmt_fuzzer.cpp) includes this file with TABLEFMT_NO_MAIN.
#ifndef TABLEFMT_NO_MAIN
int main(int argc, char** argv) {
    Options                  o;
    std::vector<std::string> files;
    for (int a = 1; a < argc; ++a) {
        std::string_view arg = argv[a];
        auto value = [&](std::string_view flag) -> std::optional<std::string> {
            if (arg.substr(0, flag.size()) == flag && arg.size() > flag.size() && arg[flag.size()] == '=')
                return std::string(arg.substr(flag.size() + 1));
            if (arg == flag && a + 1 < argc) return std::string(argv[++a]);
            return std::nullopt;
        };
        if (arg == "-h" || arg == "--help") { usage(); return 0; }
        else if (arg == "-i") o.inPlace = true;
        else if (arg == "--hug-commas") o.hugCommas = true;
        else if (arg == "--no-attach-braces") o.attachBraces = false;
        else if (arg == "--no-across-comments") o.acrossComments = false;
        else if (auto v = value("--column-limit")) o.columnLimit = std::stoi(*v);
        else if (auto v = value("--lines")) {
            int  x = 0, y = 0;
            char colon = 0;
            std::istringstream ss(*v);
            if (!(ss >> x >> colon >> y) || colon != ':' || x < 1 || y < x) {
                std::cerr << "tablefmt: bad --lines value '" << *v << "'\n";
                return 2;
            }
            o.ranges.emplace_back(x, y);
        }
        else if (!arg.empty() && arg[0] == '-' && arg != "-") { std::cerr << "tablefmt: unknown option " << arg << "\n"; return 2; }
        else files.emplace_back(arg);
    }

    if (files.empty() || (files.size() == 1 && files[0] == "-")) {
        std::string in;
        if (!readAll(std::cin, in)) { std::cerr << "tablefmt: read error\n"; return 1; }
        std::cout << formatText(in, o);
        return std::cout ? 0 : 1;
    }

    int rc = 0;
    for (const auto& f : files) {
        std::ifstream in(f, std::ios::binary);
        std::string   text;
        if (!in || !readAll(in, text)) { std::cerr << "tablefmt: cannot read " << f << "\n"; rc = 1; continue; }
        in.close();
        std::string result = formatText(text, o);
        if (o.inPlace) {
            if (result == text) continue;
            std::ofstream out(f, std::ios::binary | std::ios::trunc);
            if (!(out << result)) { std::cerr << "tablefmt: cannot write " << f << "\n"; rc = 1; }
        } else {
            std::cout << result;
        }
    }
    return rc;
}
#endif // TABLEFMT_NO_MAIN
