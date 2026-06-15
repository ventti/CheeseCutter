#!/usr/bin/env python3
"""Generate doc/ARCHITECTURE.md — a compact, auto-derived map of the project.

This is the project-native, build-free cousin of ctags / ddoc / aider's repo-map:
it parses every first-party D module under src/ (vendored derelict/ excluded) for

  * its `module a.b.c;` declaration,
  * a one-line synopsis taken from the module's header comment, and
  * its direct imports of *other first-party modules* (the dependency edges).

and emits a single Markdown file a new session can read first instead of grepping
40 modules. The module list and dependency graph are 100% derived — zero upkeep;
the only human-owned text is the per-module synopsis, which lives next to the code.

Run via `make map` (also folded into `make docs`). Output is deterministic
(sorted) so regeneration produces no spurious diff.
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "src")
OUT = os.path.join(REPO, "doc", "ARCHITECTURE.md")

# Hand-curated, near-static one-liners for the top-level packages.
PACKAGE_BLURB = {
    "(root)": "Program entry points (editor + ct2util CLI) and generated man-page tables.",
    "audio": "Audio engine: playback driver, ReSID bridge, visualizer, and remote (VICE / Ultimate) backends.",
    "audio.resid": "D-side glue to the ReSID SID emulation core.",
    "com": "Common foundation: framebuffer, keyboard, session/config, 6502 CPU, the shortcut registry and shared utilities.",
    "ct": "CheeseTracker song model: in-memory format (base), build/export, dump, and purge/optimize.",
    "seq": "Sequencer: the pattern / track data tables and follow-play that turn the song model into playback.",
    "ui": "SDL2 editor UI: top-level layout, windows, dialogs, menu bar, command palette, status bar and help.",
}

SYNOPSIS_MAX = 140  # one sentence; longer is truncated at a word boundary
LICENSE_RE = re.compile(r"Licensed under|CheeseCutter v2 \(C\)")
MODULE_RE = re.compile(r"^\s*module\s+([\w.]+)\s*;")
# matches: import a.b; / private import a.b : x; / static import a.b, c.d;
IMPORT_RE = re.compile(r"^\s*(?:public|private|static)?\s*import\s+(.+?);")


def d_files():
    for root, _dirs, files in os.walk(SRC):
        if os.sep + "derelict" + os.sep in root + os.sep:
            continue
        for f in sorted(files):
            if f.endswith(".d"):
                yield os.path.join(root, f)


def parse(path):
    """Return (module_name, synopsis, set_of_imported_module_names)."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    lines = text.splitlines()

    module = None
    imports = set()
    for ln in lines:
        m = MODULE_RE.match(ln)
        if m and module is None:
            module = m.group(1)
        im = IMPORT_RE.match(ln)
        if im:
            spec = im.group(1)
            spec = spec.split(":", 1)[0]  # drop selective-import list
            for part in spec.split(","):
                name = part.strip()
                if name:
                    imports.add(name)

    # Synopsis: the first sentence of the leading /* ... */ block's first text
    # paragraph (license line skipped). Collapsing to the first sentence turns a
    # multi-line header paragraph into a complete one-liner.
    para = []
    in_block = False
    started = False
    for ln in lines:
        stripped = ln.strip()
        if not in_block:
            if stripped.startswith("/*"):
                in_block = True
                stripped = stripped[2:].strip()
            elif stripped.startswith(("module", "import")):
                break  # no leading comment block
            else:
                continue
        if "*/" in stripped:
            stripped = stripped.split("*/", 1)[0].strip()
            ended = True
        else:
            ended = False
        if not started:
            if not stripped or LICENSE_RE.search(stripped):
                if ended:
                    break
                continue
            started = True
        if started:
            if not stripped:  # blank line ends the first paragraph
                break
            para.append(stripped)
        if ended:
            break

    text = " ".join(para).strip()
    # first sentence: up to ". " (avoids splitting ".ct" / "1.0" etc.)
    synopsis = (text.split(". ", 1)[0]).strip() if text else ""
    if synopsis and text.startswith(synopsis) and len(synopsis) < len(text):
        synopsis += "."
    # keep the table scannable: cap an over-long sentence at a word boundary.
    if len(synopsis) > SYNOPSIS_MAX:
        synopsis = synopsis[:SYNOPSIS_MAX].rsplit(" ", 1)[0].rstrip(",;:") + "…"

    return module, synopsis, imports


def package_of(module):
    return module.rsplit(".", 1)[0] if "." in module else "(root)"


def main():
    mods = {}  # module name -> dict
    for path in d_files():
        module, synopsis, imports = parse(path)
        if not module:
            # Entry-point files (e.g. ct2util.d) carry no `module` decl; use the stem.
            module = os.path.splitext(os.path.basename(path))[0]
        rel = os.path.relpath(path, REPO)
        mods[module] = {"path": rel, "synopsis": synopsis, "imports": imports}

    first_party = set(mods)

    # group by package
    packages = {}
    for name, info in mods.items():
        packages.setdefault(package_of(name), []).append(name)

    out = []
    # Agent-facing frontmatter: what this file is, how to use it, how to update it.
    out.append("---")
    out.append('purpose: "Orientation map — READ FIRST to locate a module or trace what '
               'depends on what, before grep/find. (Point lookups: just grep.)"')
    out.append("generated_by: tools/genmap.py   # do NOT edit this file; edits are overwritten")
    out.append('how_to_use: "Each row = module, one-line synopsis, first-party dependency '
               'edges. module a.b.c lives at src/a/b/c.d; open a file only after the map '
               'points you at it."')
    out.append('how_to_update: "Edit the module header\'s one-line synopsis (first sentence '
               'after the license line), then run `make map` (also in `make docs` / '
               '`mise run build`). New modules + changed imports are picked up '
               'automatically; `make check-map` fails if stale."')
    out.append('see_also: "doc/adr/ — append-only decision records: the WHY this file '
               'cannot show."')
    out.append("---")
    out.append("")
    out.append("# Architecture map")
    out.append("")
    out.append(
        "<!-- GENERATED by tools/genmap.py — do NOT hand-edit. Run `make map` "
        "(or `make docs`) to regenerate. -->"
    )
    out.append("")
    out.append(
        f"Auto-derived overview of the {len(first_party)} first-party D modules under "
        "`src/` (vendored `src/derelict/**` and the C/C++ ReSID sources are omitted). "
        "Module `a.b.c` lives at `src/a/b/c.d`. *Depends on* lists only imports of other "
        "first-party modules — the internal dependency edges."
    )
    out.append("")
    out.append(
        "The dependency graph and module list are generated from the source; the only "
        "hand-written part is each module's one-line **synopsis**, taken from its header "
        "comment. Keep that line current when a module's role changes (see CLAUDE.md)."
    )
    out.append("")
    out.append("## Packages")
    out.append("")
    out.append("| Package | Role |")
    out.append("| --- | --- |")
    for pkg in sorted(packages):
        top = pkg.split(".")[0] if pkg != "(root)" else "(root)"
        blurb = PACKAGE_BLURB.get(pkg) or PACKAGE_BLURB.get(top, "")
        out.append(f"| `{pkg}` | {blurb} |")
    out.append("")
    out.append("## Modules")
    out.append("")

    for pkg in sorted(packages):
        out.append(f"### `{pkg}`")
        out.append("")
        out.append("| Module | Synopsis | Depends on |")
        out.append("| --- | --- | --- |")
        for name in sorted(packages[pkg]):
            info = mods[name]
            deps = sorted(d for d in info["imports"] if d in first_party and d != name)
            short = name.rsplit(".", 1)[-1]
            syn = info["synopsis"] or "_(no synopsis — add a header line)_"
            dep_str = ", ".join(f"`{d}`" for d in deps) if deps else "—"
            out.append(f"| `{short}` | {syn} | {dep_str} |")
        out.append("")

    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out).rstrip() + "\n")

    undoc = [n for n, i in mods.items() if not i["synopsis"]]
    print(f"genmap: wrote {os.path.relpath(OUT, REPO)} ({len(first_party)} modules)")
    if undoc:
        print(f"genmap: {len(undoc)} module(s) without a synopsis:", file=sys.stderr)
        for n in sorted(undoc):
            print(f"  - {n} ({mods[n]['path']})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
