r"""Wrap formatted UI strings so they can be translated (Localization Phase 2).

    python tools/i18n/codemod.py scenes/ui/solar_ui.gd            # show the changes
    python tools/i18n/codemod.py scenes/ui system_graph --apply   # write them

Turns a one-line assignment of a %-formatted string to a translatable property

    load_value.text = "%s  peak %s%s" % [_fmt_power(kw), _fmt_power(pk), linked]
    lbl.tooltip_text = "%.3f kWh since midnight" % kwh

into a named-placeholder call a translator can reorder

    load_value.text = I18n.f("{power}  peak {power_2}{linked}", {"power": _fmt_power(kw), ...})
    lbl.tooltip_text = I18n.f("{kwh} kWh since midnight", {"kwh": "%.3f" % kwh})

Every %-spec other than a bare %s keeps its own formatting ("%.3f" % kwh), and
I18n.f is String.format over the translated text, so English output is
byte-for-byte what it was. What it leaves alone (listed with --verbose):
  - templates with no word of 2+ letters ("%s%s", "%.0f%%");
  - multi-line expressions, a % whose right side has a top-level if/else,
    templates already holding { or }, %c / %x / %o / %*;
  - lines marked `# i18n:skip`, and every file extract.py skips.
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
import extract  # noqa: E402

ROOT = extract.ROOT
PROPS = r"(?:text|tooltip_text|placeholder_text|title|dialog_text)"
LINE = re.compile(r"^(?P<ind>\s*)(?P<lhs>(?:[\w.\[\]\"()]+\.)?" + PROPS + r")\s*=\s*"
                  r"\"(?P<fmt>(?:[^\"\\\n]|\\.)*)\"\s*%\s*(?P<args>.+?)\s*(?P<cmt>#.*)?$")
SPEC = re.compile(r"%(?P<flags>[-+ 0#]*)(?P<width>\d+)?(?:\.(?P<prec>\d+))?(?P<conv>[sdif%xXocv*])")
WORD = re.compile(r"[A-Za-z]{2,}")
IDENT = re.compile(r"[A-Za-z_]\w*")
STOP = {"str", "int", "float", "abs", "round", "roundi", "maxf", "minf", "max", "min", "clampf", "clampi",
        "size", "get", "length", "text", "value", "self", "len", "floor", "ceil", "snapped", "abs", "absf",
        "duplicate", "keys", "values", "join", "format", "strip_edges", "to_upper", "to_lower", "capitalize",
        "true", "false", "null", "and", "or", "not", "if", "else", "in", "as", "UiText", "num", "count",
        "fmt", "s", "i", "n", "x", "v"}


def split_args(src: str) -> list[str] | None:
    """`[a, b(c, d), e]` -> ['a', 'b(c, d)', 'e']; a single expression -> [it]."""
    s = src.strip()
    if s.startswith("(") and _close(s, 0) == len(s) - 1:
        return [s]   # one parenthesised operand, whatever is inside
    if s.startswith("[") and _close(s, 0) == len(s) - 1:
        body = s[1:-1]
        parts, depth, cur, q = [], 0, "", ""
        for ch in body:
            if q:
                cur += ch
                if ch == q and not cur.endswith("\\" + q):
                    q = ""
                continue
            if ch in "\"'":
                q = ch
            elif ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            if ch == "," and depth == 0:
                parts.append(cur.strip())
                cur = ""
            else:
                cur += ch
        if cur.strip():
            parts.append(cur.strip())
        return parts
    if re.search(r"(?<![\w\"])(if|else)(?![\w\"])", _strip_strings(s)):
        return None   # `"x %s" % a if c else b`: the % binds tighter, unsafe to rewrite
    if _strip_strings(s).count("(") != _strip_strings(s).count(")"):
        return None
    return [s]


def split_tail(src: str) -> tuple[str | None, str]:
    """The % operand and what follows it: `[a, b] if c else ""` -> ('[a, b]', ' if c else ""').

    `%` binds tighter than `if`, so the operand ends at the first top-level `if`
    (or the closing bracket of a list / parenthesised operand)."""
    s = src.strip()
    if s[:1] in "[(":
        j = _close(s, 0)
        if j < 0:
            return None, ""
        rest = s[j + 1:]
        if rest.strip() and not re.match(r"\s+if\s", rest):
            return None, ""
        return s[:j + 1], (" " + rest.strip()) if rest.strip() else ""
    m = re.search(r"\sif\s", _mask(s))
    if m:
        return s[:m.start()].strip(), " " + s[m.start():].strip()
    return s, ""


def _mask(s: str) -> str:
    """s with every string literal's inside replaced by '_' (same length)."""
    out, q, esc = [], "", False
    for ch in s:
        if q:
            if esc:
                esc = False
                out.append("_")
            elif ch == "\\":
                esc = True
                out.append("_")
            elif ch == q:
                q = ""
                out.append(ch)
            else:
                out.append("_")
        else:
            if ch in "\"'":
                q = ch
            out.append(ch)
    return "".join(out)


def _strip_strings(s: str) -> str:
    return re.sub(r"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'", '""', s)


def _close(s: str, i: int) -> int:
    depth, q = 0, ""
    for j in range(i, len(s)):
        ch = s[j]
        if q:
            if ch == q and s[j - 1] != "\\":
                q = ""
            continue
        if ch in "\"'":
            q = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return j
    return -1


def name_for(expr: str, used: set[str]) -> str:
    """A placeholder name from the argument: the last meaningful identifier."""
    # A dictionary key names the value best: t["cost"], d.get("name", "?") -> cost, name.
    keys = re.findall(r"(?:\[|\.get\(\s*)\"([A-Za-z_]\w*)\"", expr)
    toks = [t for t in IDENT.findall(_strip_strings(expr)) if t not in STOP]
    base = (keys[-1] if keys else toks[-1] if toks else "value").lstrip("_").lower()
    base = re.sub(r"^(fmt|get|lbl|txt|str|cur|last|new|old|the)_", "", base) or "value"
    base = re.sub(r"_(lbl|label|txt|str|val|value)$", "", base) or "value"
    if base[0].isdigit():
        base = "v" + base
    name, k = base, 2
    while name in used:
        name = f"{base}_{k}"
        k += 1
    used.add(name)
    return name


def convert(line: str) -> tuple[str | None, str]:
    """(new line, '') or (None, why it was left)."""
    if "i18n:skip" in line or "I18n." in line:
        return None, "skip"
    m = LINE.match(line.rstrip("\r\n"))
    if not m:
        return None, "shape"
    fmt, args_src = m.group("fmt"), m.group("args")
    if "{" in fmt or "}" in fmt:
        return None, "braces"
    specs = list(SPEC.finditer(fmt))
    real = [s for s in specs if s.group("conv") != "%"]
    if any(s.group("conv") in "xXoc*v" for s in real):
        return None, "spec"
    if not WORD.search(SPEC.sub("", fmt)):
        return None, "no words"
    args_src, tail = split_tail(args_src)
    if args_src is None:
        return None, "args"
    args = split_args(args_src)
    if args is None or len(args) != len(real):
        return None, "args"
    used: set[str] = set()
    out, pairs, pos, k = "", [], 0, 0
    for s in specs:
        out += fmt[pos:s.start()]
        pos = s.end()
        if s.group("conv") == "%":
            out += "%"
            continue
        expr = args[k]
        k += 1
        nm = name_for(expr, used)
        out += "{" + nm + "}"
        spec_txt = s.group(0)
        val = expr if spec_txt == "%s" else f'"{spec_txt}" % ({expr})' if " " in expr.strip() or "?" in expr \
            else f'"{spec_txt}" % {expr}'
        pairs.append(f'"{nm}": {val}')
    out += fmt[pos:]
    ind = m.group("ind")
    head = f'{ind}{m.group("lhs")} = I18n.f("{out}", {{'
    one = head + ", ".join(pairs) + "})" + tail
    if len(one.expandtabs(4)) <= 140:
        new = one
    else:   # one value a line, as the original list was laid out
        new = head + "\n" + "".join(f"{ind}\t{p},\n" for p in pairs) + f"{ind}}}){tail}"
    if m.group("cmt"):
        new += "  " + m.group("cmt")
    eol = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
    return new + eol, ""


def join_statement(lines: list[str], i: int) -> tuple[str | None, int]:
    """Line i plus the lines its statement runs on to (an open bracket, a trailing
    backslash), as one line with the first line's end of line; and the index after
    it. None when a line inside carries a comment (it would be lost)."""
    eol = "\r\n" if lines[i].endswith("\r\n") else "\n" if lines[i].endswith("\n") else ""
    text = lines[i].rstrip("\r\n")
    j = i + 1
    while j < len(lines) and j - i <= 14:
        body = _mask(text.split(" % ", 1)[1]) if " % " in text else ""
        depth = sum(body.count(c) for c in "([{") - sum(body.count(c) for c in ")]}")
        cont = text.rstrip().endswith("\\")
        if depth <= 0 and not cont:
            break
        nxt = lines[j].rstrip("\r\n").strip()
        if "#" in _mask(nxt):
            return None, i + 1
        text = (text.rstrip()[:-1].rstrip() if cont else text.rstrip()) + " " + nxt
        j += 1
    return text + eol, j


def files_under(paths: list[str]) -> list[str]:
    out = []
    for p in paths:
        ap = os.path.join(ROOT, p)
        if os.path.isfile(ap):
            out.append(ap)
            continue
        for dirpath, dirnames, filenames in os.walk(ap):
            dirnames[:] = sorted(d for d in dirnames if d not in extract.SKIP_DIRS)
            out += [os.path.join(dirpath, f) for f in sorted(filenames)
                    if f.endswith(".gd") and not extract.SKIP_FILE_RE.search(f)]
    return out


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--verbose", action="store_true", help="list the lines left alone and why")
    args = ap.parse_args()
    total = left = 0
    for path in files_under(args.paths):
        with open(path, encoding="utf-8", newline="") as fh:
            lines = fh.readlines()
        if any("i18n:skip-file" in ln for ln in lines[:15]):
            continue
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        new_lines, n = [], 0
        i = 0
        while i < len(lines):
            ln = lines[i]
            if "%" not in ln or "=" not in ln or not LINE.match(ln.rstrip("\r\n")):
                new_lines.append(ln)
                i += 1
                continue
            stmt, j = join_statement(lines, i)
            new, why = convert(stmt) if stmt is not None else (None, "comments")
            if new is None:
                if why not in ("shape", "skip") and args.verbose:
                    print(f"  left ({why}) {rel}:{i + 1}: {ln.strip()[:110]}")
                if why not in ("shape", "skip"):
                    left += 1
                new_lines.append(ln)
                i += 1
            else:
                new_lines.append(new)
                n += 1
                i = j
        if not n:
            continue
        total += n
        if args.apply:
            with open(path, "w", encoding="utf-8", newline="") as fh:
                fh.writelines(new_lines)
            print(f"  {n:3d}  {rel}")
        else:
            sys.stdout.writelines(difflib.unified_diff(lines, new_lines, rel, rel, n=0))
    print(f"codemod: {total} lines {'rewritten' if args.apply else 'to rewrite'}, {left} formatted lines left for hand fixes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
