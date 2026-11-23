"""Small gettext .po / .pot reader and writer (stdlib only).

Enough of the format for the game's pipeline: msgctxt, msgid, msgid_plural,
msgstr / msgstr[n], translator comments (#), extracted comments (#.),
references (#:), flags (#,), previous msgid (#| msgid). Obsolete (#~)
entries are dropped on read.

An Entry's key is (ctx, msgid). Files are written UTF-8 with LF endings.
"""

from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass, field


@dataclass
class Entry:
    msgid: str
    ctx: str = ""
    plural: str = ""
    msgstr: list[str] = field(default_factory=lambda: [""])
    comments: list[str] = field(default_factory=list)    # "# ..." translator / tool notes
    extracted: list[str] = field(default_factory=list)   # "#. ..." from the source
    refs: list[str] = field(default_factory=list)        # "#: path:line"
    flags: list[str] = field(default_factory=list)       # "#, fuzzy"
    previous: str = ""                                    # "#| msgid" before a source change

    @property
    def key(self) -> tuple[str, str]:
        return (self.ctx, self.msgid)

    @property
    def translated(self) -> bool:
        return all(s != "" for s in self.msgstr) and "fuzzy" not in self.flags

    def has_flag(self, f: str) -> bool:
        return f in self.flags

    def set_flag(self, f: str, on: bool = True) -> None:
        if on and f not in self.flags:
            self.flags.append(f)
        elif not on and f in self.flags:
            self.flags.remove(f)

    def comment_value(self, prefix: str) -> str:
        """A '# prefix: value' tool note."""
        for c in self.comments:
            if c.startswith(prefix + ":"):
                return c[len(prefix) + 1:].strip()
        return ""

    def set_comment(self, prefix: str, value: str) -> None:
        self.comments = [c for c in self.comments if not c.startswith(prefix + ":")]
        if value:
            self.comments.append(f"{prefix}: {value}")


@dataclass
class Catalog:
    header: dict[str, str] = field(default_factory=dict)
    entries: list[Entry] = field(default_factory=list)

    def index(self) -> dict[tuple[str, str], Entry]:
        return {e.key: e for e in self.entries}


_ESC = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}


def unescape(s: str) -> str:
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            out.append(_ESC.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n")


def _quoted(line: str) -> str:
    m = re.match(r'^\s*"(.*)"\s*$', line)
    return unescape(m.group(1)) if m else ""


def read(path: str) -> Catalog:
    cat = Catalog()
    cur: Entry | None = None
    pending: dict = {"comments": [], "extracted": [], "refs": [], "flags": [], "previous": ""}
    field_name = None
    plural_idx = 0

    def flush():
        nonlocal cur
        if cur is None:
            return
        if cur.msgid == "" and cur.ctx == "":
            for ln in cur.msgstr[0].split("\n"):
                if ":" in ln:
                    k, v = ln.split(":", 1)
                    cat.header[k.strip()] = v.strip()
        else:
            cat.entries.append(cur)
        cur = None

    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    for raw in lines + [""]:
        line = raw.rstrip("\n")
        if line.startswith("#~"):
            continue
        if line.strip() == "":
            flush()
            field_name = None
            continue
        if line.startswith("#"):
            if cur is not None and field_name is not None:
                flush()
                field_name = None
            if line.startswith("#."):
                pending["extracted"].append(line[2:].strip())
            elif line.startswith("#:"):
                pending["refs"].extend(line[2:].split())
            elif line.startswith("#,"):
                pending["flags"].extend(f.strip() for f in line[2:].split(",") if f.strip())
            elif line.startswith("#|"):
                m = re.match(r'#\|\s*msgid\s+"(.*)"', line)
                if m:
                    pending["previous"] = unescape(m.group(1))
            else:
                pending["comments"].append(line[1:].strip())
            continue

        def start():
            nonlocal cur, pending
            if cur is None:
                cur = Entry(msgid="", msgstr=[""])
                cur.comments, cur.extracted, cur.refs = pending["comments"], pending["extracted"], pending["refs"]
                cur.flags, cur.previous = pending["flags"], pending["previous"]
                pending = {"comments": [], "extracted": [], "refs": [], "flags": [], "previous": ""}

        m = re.match(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[(\d+)\])?)\s+(".*")\s*$', line)
        if m:
            kw = m.group(1)
            val = _quoted(m.group(3))
            if kw == "msgctxt":
                flush()
                start()
                cur.ctx = val
                field_name = "ctx"
            elif kw == "msgid":
                if cur is not None and field_name not in ("ctx",):
                    flush()
                start()
                cur.msgid = val
                field_name = "msgid"
            elif kw == "msgid_plural":
                cur.plural = val
                field_name = "plural"
            else:
                idx = int(m.group(2)) if m.group(2) is not None else 0
                while len(cur.msgstr) <= idx:
                    cur.msgstr.append("")
                cur.msgstr[idx] = val
                field_name = "msgstr"
                plural_idx = idx
            continue
        if line.lstrip().startswith('"') and cur is not None:
            val = _quoted(line)
            if field_name == "ctx":
                cur.ctx += val
            elif field_name == "msgid":
                cur.msgid += val
            elif field_name == "plural":
                cur.plural += val
            elif field_name == "msgstr":
                cur.msgstr[plural_idx] += val
    return cat


def _wrap(kw: str, s: str) -> list[str]:
    if "\n" in s.rstrip("\n") or len(s) > 70:
        parts = re.split(r"(?<=\n)", s)
        out = [f'{kw} ""']
        for p in parts:
            if p:
                out.append(f'"{escape(p)}"')
        return out
    return [f'{kw} "{escape(s)}"']


def write(path: str, cat: Catalog, header_order: list[str] | None = None) -> None:
    lines: list[str] = []
    keys = header_order or list(cat.header.keys())
    hdr = "".join(f"{k}: {cat.header[k]}\n" for k in keys if k in cat.header)
    lines += ['msgid ""', 'msgstr ""'] + [f'"{escape(l)}\\n"' for l in hdr.splitlines()] + [""]
    for e in cat.entries:
        for c in e.comments:
            lines.append(f"# {c}".rstrip())
        for c in e.extracted:
            lines.append(f"#. {c}".rstrip())
        if e.refs:
            lines.append("#: " + " ".join(e.refs))
        if e.flags:
            lines.append("#, " + ", ".join(e.flags))
        if e.previous:
            lines.append(f'#| msgid "{escape(e.previous)}"')
        if e.ctx:
            lines += _wrap("msgctxt", e.ctx)
        lines += _wrap("msgid", e.msgid)
        if e.plural:
            lines += _wrap("msgid_plural", e.plural)
            for i, s in enumerate(e.msgstr):
                lines += _wrap(f"msgstr[{i}]", s)
        else:
            lines += _wrap("msgstr", e.msgstr[0] if e.msgstr else "")
        lines.append("")
    # Written beside the file and swapped in. On Windows another reader (an
    # editor, the indexer, antivirus) can hold the .po for a moment and the open
    # fails with EINVAL / EACCES: retry instead of losing an hour of work.
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    for attempt in range(20):
        try:
            os.replace(tmp, path)
            return
        except OSError:
            if attempt == 19:
                raise
            time.sleep(0.5)


# Placeholders a translation must keep: {name}, %s %d %.1f %5.2f, %%, BBCode tags.
PLACEHOLDER_RE = re.compile(r"\{[A-Za-z_][A-Za-z0-9_]*\}|%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?[sdifxXeEgGc]|%%|\[/?[a-z_]+(?:=[^\]]*)?\]")


def placeholders(s: str) -> list[str]:
    return sorted(PLACEHOLDER_RE.findall(s))


# gettext plural rules for the languages the game ships, by language code.
PLURAL_FORMS = {
    "ar": "nplurals=6; plural=(n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5);",
    "ru": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "uk": "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "pl": "nplurals=3; plural=(n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
    "fr": "nplurals=2; plural=(n > 1);",
    "pt_BR": "nplurals=2; plural=(n > 1);",
    "hi": "nplurals=2; plural=(n > 1);",
    "bn": "nplurals=2; plural=(n > 1);",
    "fa": "nplurals=2; plural=(n > 1);",
    "zh_Hans": "nplurals=1; plural=0;",
    "zh_Hant": "nplurals=1; plural=0;",
    "yue": "nplurals=1; plural=0;",
    "ja": "nplurals=1; plural=0;",
    "ko": "nplurals=1; plural=0;",
    "th": "nplurals=1; plural=0;",
    "vi": "nplurals=1; plural=0;",
    "id": "nplurals=1; plural=0;",
    "ms": "nplurals=1; plural=0;",
    "tr": "nplurals=2; plural=(n != 1);",
}
DEFAULT_PLURAL = "nplurals=2; plural=(n != 1);"


def plural_forms(code: str) -> str:
    return PLURAL_FORMS.get(code, PLURAL_FORMS.get(code.split("_")[0], DEFAULT_PLURAL))


def nplurals(code: str) -> int:
    m = re.search(r"nplurals=(\d+)", plural_forms(code))
    return int(m.group(1)) if m else 2


HEADER_ORDER = ["Project-Id-Version", "Language", "MIME-Version", "Content-Type",
                "Content-Transfer-Encoding", "Plural-Forms", "X-Generator"]


def header_for(code: str) -> dict[str, str]:
    return {
        "Project-Id-Version": "SIMbiogenesis",
        "Language": code,
        "MIME-Version": "1.0",
        "Content-Type": "text/plain; charset=UTF-8",
        "Content-Transfer-Encoding": "8bit",
        "Plural-Forms": plural_forms(code),
        "X-Generator": "tools/i18n",
    }
