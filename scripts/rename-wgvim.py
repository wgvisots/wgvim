#!/usr/bin/env python3
"""Rename the user-facing identity of this tree from Neovim to wgvim.

Reproducible and idempotent. Run with --apply to write changes; the default is a
dry run that prints per-rule counts. Only tracked, non-vendored text files are
touched. Internal identifiers (the `nvim_*` API functions, `src/nvim/`, the `vim`
Lua namespace, `nvim_bin`) are deliberately left alone: renaming them would break
every Lua plugin and the whole runtime for no user-visible gain.

Credit is preserved: LICENSE.txt, vendored sources, URLs, and any line that looks
like a copyright / authorship / provenance statement are never rewritten.
"""
import re
import subprocess
import sys

APPLY = "--apply" in sys.argv

# Files never touched (third-party code with its own licence, licences, translations
# whose msgids must keep matching, binaries are skipped by the decode check).
SKIP_PREFIXES = (
    "deps/", "src/mpack/", "src/lpeg/", "src/cjson/", "src/klib/", "src/tee/",
    "src/xxd/", "src/xdiff/", "src/nvim/po/", "src/nvim/vterm/", "src/nvim/tui/termkey/",
)
SKIP_NAMES = ("LICENSE.txt", "NOTICE", "ATTRIBUTION.md", "scripts/rename-wgvim.py")

# A line mentioning any of these is credit/provenance, not branding: leave it.
PROTECT = re.compile(
    r"copyright|maintainer|author|contributor|licen[cs]e|forked|derived|based on|"
    r"upstream|credit|acknowledg|thanks|originally|https?://|neovim\.io|neovim/neovim",
    re.I,
)

# Environment variables read or set by the program (exact tokens only).
ENV_TOKENS = [
    "NVIM_APPNAME", "NVIM_LOG_FILE", "NVIM_LISTEN_ADDRESS", "NVIM_TERMDEFS",
    "NVIM_NOTTYFAST", "NVIM_TEST", "NVIM_LUA_NOTRACK", "NVIM_RPLUGIN_MANIFEST",
    "NVIM_NODE_HOST_DEBUG", "NVIM_TUI_ENABLE_CURSOR_SHAPE", "NVIM_PRG",
    "__NVIM_LOG_FILE_WANT", "__NVIM_STARTREASON", "__NVIM_TEST_LOG",
]

# (name, compiled regex, replacement, protect_credit_lines)
RULES = []
for tok in ENV_TOKENS:
    RULES.append((f"env {tok}",
                  re.compile(r"(?<![A-Za-z0-9_])" + re.escape(tok) + r"(?![A-Za-z0-9_])"),
                  tok.replace("NVIM", "WGVIM"), False))

RULES += [
    ("env $NVIM", re.compile(r"\$NVIM(?![A-Za-z0-9_])"), "$WGVIM", False),
    ("env vim.env.NVIM", re.compile(r"vim\.env\.NVIM(?![A-Za-z0-9_])"), "vim.env.WGVIM", False),
    ("env env['NVIM']", re.compile(r"env\['NVIM'\]"), "env['WGVIM']", False),
    ("env ENV_NVIM", re.compile(r'#define ENV_NVIM "NVIM"'), '#define ENV_NVIM "WGVIM"', False),
    ("env S_LEN(NVIM)", re.compile(r'S_LEN\("NVIM"\)'), 'S_LEN("WGVIM")', False),
    ("env getenv(NVIM)", re.compile(r'os_getenv_noalloc\("NVIM"\)'), 'os_getenv_noalloc("WGVIM")', False),
    # banner and the code that parses it
    ("banner", re.compile(r'"NVIM " NVIM_VERSION_MEDIUM'), '"WGVIM " NVIM_VERSION_MEDIUM', False),
    ("banner parse", re.compile(r"match\('NVIM \(v"), "match('WGVIM (v", False),
    ("banner NVIM v", re.compile(r"\bNVIM v(?=[0-9])"), "WGVIM v", False),
    ("default appname", re.compile(r'xstrlcpy\(NameBuff, "nvim"'), 'xstrlcpy(NameBuff, "wgvim"', False),
    ("argv0 default", re.compile(r'argv0 \? argv0 : "nvim"'), 'argv0 ? argv0 : "wgvim"', False),
    # install layout and per-user directories (these follow the app name)
    ("dir share/lib", re.compile(r"\b(share|lib)/nvim\b"), r"\1/wgvim", False),
    ("dir cmake", re.compile(r"(\$\{CMAKE_INSTALL_(?:DATAROOTDIR|DATADIR|LIBDIR)\})/nvim\b"), r"\1/wgvim", False),
    ("dir xdg", re.compile(r"(\.config|\.cache|\.local/state|\.local/share|XDG_[A-Z_]+(?:\})?|AppData/Local|AppData\\Local)([/\\])nvim(?![A-Za-z0-9_.-])"), r"\1\2wgvim", False),
    ("dir nvim-data", re.compile(r"\bnvim-data\b"), "wgvim-data", False),
    ("binary path", re.compile(r"\bbin/nvim\b(?!\.)"), "bin/wgvim", False),
    ("binary output", re.compile(r"OUTPUT_NAME nvim\b"), "OUTPUT_NAME wgvim", False),
    # prose: project name in messages, comments and docs
    ("prose Neovim", re.compile(r"\bNeovim\b"), "wgvim", True),
    ("prose Nvim", re.compile(r"\bNvim\b"), "wgvim", True),
]

files = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split("\n")
counts = {}
changed_files = 0
for path in files:
    if not path or path.startswith(SKIP_PREFIXES) or path in SKIP_NAMES:
        continue
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
        text = raw.decode("utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    out = []
    dirty = False
    for line in text.split("\n"):
        new = line
        for name, rx, repl, protect in RULES:
            if protect and PROTECT.search(new):
                continue
            new, n = rx.subn(repl, new)
            if n:
                counts[name] = counts.get(name, 0) + n
        if new != line:
            dirty = True
        out.append(new)
    if dirty:
        changed_files += 1
        if APPLY:
            with open(path, "wb") as fh:
                fh.write("\n".join(out).encode("utf-8"))

print(("APPLIED" if APPLY else "DRY RUN") + f": {changed_files} files")
for name, n in sorted(counts.items(), key=lambda kv: -kv[1]):
    print(f"  {n:6d}  {name}")
