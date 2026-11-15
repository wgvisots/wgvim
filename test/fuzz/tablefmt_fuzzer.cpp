// wgvim: libFuzzer harness for tablefmt (src/tablefmt; test/fuzz/README.md).
//
// tablefmt rewrites the user's C/C++ text, so on any input it must keep its promise that only
// whitespace changes: as many lines, and each line has the same tokens and comment. Any break
// is reported as a crash, besides ASan/UBSan findings. This is what CI checks.
//
// With TABLEFMT_FUZZ_STRICT=1 in the environment, also (for hunting alignment bugs):
//   - running it again on its output changes nothing (idempotence);
//   - its own safety net (a rewritten line that re-lexes differently, which it then leaves
//     unchanged) never fires.
// Both still break on some inputs that are not code (lines starting with "=", runs of NUL
// bytes; see SECURITY-AUDIT.md), which is why they are not on in CI.
//
// Input: one option byte, then the text.
//   bit 0 --hug-commas, bit 1 --no-attach-braces, bit 2 --no-across-comments,
//   bit 3 --column-limit (40 + 8 * the high nibble)

#define TABLEFMT_NO_MAIN
#include "../../src/tablefmt/tablefmt.cpp"

#include <cstdint>
#include <cstdlib>

namespace {

std::vector<std::string> splitLines(const std::string& s) {
    std::vector<std::string> v;
    size_t start = 0;
    for (;;) {
        size_t nl = s.find('\n', start);
        v.push_back(s.substr(start, nl == std::string::npos ? std::string::npos : nl - start));
        if (nl == std::string::npos) return v;
        start = nl + 1;
    }
}

void check(bool ok, const char* what) {
    if (!ok) {
        std::fprintf(stderr, "tablefmt_fuzzer: %s\n", what);
        std::abort();
    }
}

} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size < 1 || size > 65536) return 0;
    const uint8_t f = data[0];
    Options o;
    o.hugCommas      = f & 1;
    o.attachBraces   = !(f & 2);
    o.acrossComments = !(f & 4);
    o.columnLimit    = (f & 8) ? 40 + (f >> 4) * 8 : 0;
    const std::string in(reinterpret_cast<const char*>(data) + 1, size - 1);

    const std::string out = formatText(in, o);
    const auto a = splitLines(in), b = splitLines(out);
    check(a.size() == b.size(), "the number of lines changed");
    for (size_t i = 0; i < a.size(); ++i) {
        if (a[i] == b[i]) continue;
        std::string ca, cb;
        check(tokenTexts(a[i], &ca) == tokenTexts(b[i], &cb), "a line's tokens changed");
        check(ca == cb, "a line's comment changed");
    }
    static const bool strict = std::getenv("TABLEFMT_FUZZ_STRICT") != nullptr;
    if (strict) check(formatText(out, o) == out, "not idempotent");
    return 0;
}
