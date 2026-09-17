#!/usr/bin/env python3
"""Extract a conservative, machine-readable FNV ESM schema from xEdit's Pascal DSL.

This is intentionally *not* a Delphi compiler.  wbDefinitionsFNV.pas builds
definitions at run time, including definitions imported from
wbDefinitionsCommon.pas.  Treating it as text is sufficient for a useful
coverage inventory, as long as this tool reports helpers it cannot expand
instead of inventing subrecords for them.

The JSON is a reference inventory: record -> known subrecord tags, the xEdit
constructor responsible for each tag, and source line.  It is useful for
comparing a new EsmFile decoder with the documented shape of a record; it is
not evidence that every listed field needs to be decoded by the engine.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Iterator


LEAF_PREFIXES = (
    "wbString", "wbInteger", "wbFloat", "wbFormID", "wbByteArray",
    "wbEmpty", "wbStruct", "wbArray", "wbLString", "wbRaw",
)
CONTAINER_PREFIXES = (
    "wbRStruct", "wbRArray", "wbRUnion", "wbUnion", "wbModel",
)
SCHEMA_CALLS = LEAF_PREFIXES + CONTAINER_PREFIXES
RECORD_CALLS = {"wbRecord", "wbRefRecord"}
TAG = re.compile(r"^[A-Z0-9_]{4}$")
IDENT = re.compile(r"\b(wb[A-Za-z0-9_]+)\b")
CALL_START = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def scrub_comments(text: str) -> str:
    """Blank Pascal comments without changing offsets or line numbers."""
    result = list(text)
    i = 0
    quote = ""
    while i < len(text):
        if quote:
            if text[i] == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    i += 2
                    continue
                quote = False
            i += 1
            continue
        if text[i] == "'":
            quote = True
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
            for j in range(i, end):
                result[j] = " "
            i = end
        elif text.startswith("{", i) or text.startswith("(*", i):
            close = "}" if text[i] == "{" else "*)"
            end = text.find(close, i + len(close) - 1)
            end = len(text) if end < 0 else end + len(close)
            for j in range(i, end):
                if result[j] != "\n":
                    result[j] = " "
            i = end
        else:
            i += 1
    return "".join(result)


def close_bracket(text: str, opening: int) -> int:
    """Return matching ) / ] / } while respecting Pascal string literals."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[text[opening]]]
    i = opening + 1
    quote = False
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == quote:
                if quote == "'" and i + 1 < len(text) and text[i + 1] == "'":
                    i += 2
                    continue
                quote = ""
            elif quote == '"' and ch == "\\":
                i += 2
                continue
        elif ch in "'\"":
            quote = ch
        elif ch in pairs:
            stack.append(pairs[ch])
        elif stack and ch == stack[-1]:
            stack.pop()
            if not stack:
                return i
        i += 1
    raise ValueError(f"unbalanced delimiter at offset {opening}")


def split_args(text: str) -> list[str]:
    """Split a Pascal call's argument text only at its top-level commas."""
    args, start, stack, quote = [], 0, [], False
    pairs = {"(": ")", "[": "]", "{": "}"}
    for i, ch in enumerate(text):
        if quote:
            if ch == "'":
                # Escaped Pascal quote.
                if i + 1 < len(text) and text[i + 1] == "'":
                    continue
                quote = False
        elif ch == "'":
            quote = True
        elif ch in pairs:
            stack.append(pairs[ch])
        elif stack and ch == stack[-1]:
            stack.pop()
        elif ch == "," and not stack:
            args.append(text[start:i].strip())
            start = i + 1
    args.append(text[start:].strip())
    return args


def calls(text: str, base: int = 0) -> Iterator[tuple[str, list[str], int, str]]:
    """Yield every (including nested) call as name, args, offset, raw text."""
    pos = 0
    while (match := CALL_START.search(text, pos)):
        name = match.group(1)
        opening = match.end() - 1
        try:
            closing = close_bracket(text, opening)
        except ValueError:
            return
        raw = text[match.start():closing + 1]
        args_text = text[opening + 1:closing]
        yield name, split_args(args_text), base + match.start(), raw
        yield from calls(args_text, base + opening + 1)
        pos = closing + 1


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def tag_from_argument(argument: str) -> str | None:
    value = argument.strip()
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        value = value[1:-1].replace("''", "'")
    return value if TAG.fullmatch(value) else None


def semicolon_after(text: str, start: int) -> int:
    """Find an assignment's terminating semicolon, not a nested one."""
    stack, quote = [], False
    pairs = {"(": ")", "[": "]", "{": "}"}
    i = start
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    i += 2
                    continue
                quote = False
        elif ch == "'":
            quote = True
        elif ch in pairs:
            stack.append(pairs[ch])
        elif stack and ch == stack[-1]:
            stack.pop()
        elif ch == ";" and not stack:
            return i
        i += 1
    return len(text)


def assigned_definitions(text: str) -> dict[str, tuple[str, int]]:
    definitions: dict[str, tuple[str, int]] = {}
    for match in re.finditer(r"\b(wb[A-Za-z0-9_]+)\s*:=", text):
        start = match.end()
        end = semicolon_after(text, start)
        value = text[start:end].strip()
        # Enum/value lists are not schema nodes.  Keeping only values that
        # contain a schema constructor prevents the resolver visiting huge
        # condition/enumeration tables.
        if any(prefix in value for prefix in SCHEMA_CALLS):
            definitions[match.group(1)] = (value, start)
    return definitions


def result_definitions(text: str) -> dict[str, tuple[str, int]]:
    """Extract local helper functions such as wbGenericModel's Result := ... ."""
    definitions: dict[str, tuple[str, int]] = {}
    pattern = re.compile(r"\bfunction\s+(wb[A-Za-z0-9_]+)\b", re.IGNORECASE)
    for match in pattern.finditer(text):
        begin = re.search(r"\bbegin\b", text[match.end():], re.IGNORECASE)
        if not begin:
            continue
        body_start = match.end() + begin.end()
        next_end = re.search(r"\bend\s*;", text[body_start:], re.IGNORECASE)
        if not next_end:
            continue
        body_end = body_start + next_end.start()
        body = text[body_start:body_end]
        result = re.search(r"\bResult\s*:=", body, re.IGNORECASE)
        if not result:
            continue
        value_start = body_start + result.end()
        value_end = semicolon_after(text, value_start)
        value = text[value_start:value_end].strip()
        if any(prefix in value for prefix in SCHEMA_CALLS):
            definitions[match.group(1)] = (value, value_start)
    return definitions


def extract_records(text: str) -> list[tuple[str, str, str, int]]:
    records = []
    for name, args, offset, raw in calls(text):
        if name not in RECORD_CALLS or len(args) < 2:
            continue
        tag = tag_from_argument(args[0])
        display = args[1].strip().strip("'")
        if tag:
            records.append((tag, display, raw, offset))
    return records


def schema_for_record(
    expression: str,
    base_offset: int,
    source: str,
    definitions: dict[str, tuple[str, int]],
) -> tuple[dict[str, list[dict]], list[str]]:
    fields: dict[str, list[dict]] = defaultdict(list)
    opaque: set[str] = set()
    visited: set[str] = set()

    def visit(value: str, offset: int, path: list[str]) -> None:
        for name, args, call_offset, raw in calls(value, offset):
            if name.startswith(LEAF_PREFIXES) and args:
                tag = tag_from_argument(args[0])
                if tag:
                    description = ""
                    if len(args) > 1 and args[1].strip().startswith("'"):
                        description = args[1].strip().strip("'").replace("''", "'")
                    fields[tag].append({
                        "constructor": name,
                        "description": description,
                        "line": line_of(source, call_offset),
                        "via": path,
                    })
            # A call could be a local helper that itself contains fields.
            if name in definitions and name not in visited:
                visited.add(name)
                subexpr, suboffset = definitions[name]
                visit(subexpr, suboffset, path + [name])
            elif name.startswith("wb") and name not in RECORD_CALLS and not name.startswith(SCHEMA_CALLS):
                # Only retain helpers which appear as an element/call in this
                # schema; callback calls such as SetRequired are deliberately
                # excluded because they do not define bytes on disk.
                if not name.startswith("wb") or name.startswith("wbFlag"):
                    continue
                if not name.startswith(("wbCondition", "wbEnum", "wbFlags", "wbCollapse", "wbVec", "wbByteColors")):
                    opaque.add(name)
        # Aliases can occur without parentheses, e.g. wbEDID in an array.
        for identifier_match in IDENT.finditer(value):
            identifier = identifier_match.group(1)
            # Calls have already been handled above.  This branch is only for
            # a schema member used bare in an array/struct.
            if value[identifier_match.end():].lstrip().startswith("("):
                continue
            if identifier in definitions and identifier not in visited:
                visited.add(identifier)
                subexpr, suboffset = definitions[identifier]
                visit(subexpr, suboffset, path + [identifier])
            elif identifier not in definitions:
                # Common xEdit members are often used bare in a record array
                # (wbLandLayers, wbObjectBounds, ...), not called.  Record
                # them too: omitting them would make LAND look exhaustively
                # specified when its important payload is actually imported
                # from wbDefinitionsCommon.
                if not identifier.startswith((
                    "wbCondition", "wbEnum", "wbFlags", "wbCollapse",
                    "wbVec", "wbByteColors", "wbFlag",
                )) and identifier not in RECORD_CALLS:
                    opaque.add(identifier)

    visit(expression, base_offset, [])
    # The record constructor's first argument is a record signature, not a
    # subrecord.  It is intentionally absent from fields.
    return dict(sorted(fields.items())), sorted(opaque)


def cpp_strings_by_method(cpp: str) -> dict[str, dict[str, object]]:
    """Conservative static evidence: record guards and subrecord tags per method."""
    # Preserve offsets (for the function-header matches) while making braces
    # in comments irrelevant to the small C++ scanner below.
    cpp = re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), cpp)
    out: dict[str, dict[str, object]] = {}
    pattern = re.compile(r"\b(?:std::[A-Za-z0-9_:<> ,]+|[A-Za-z0-9_:<> ,]+)\s+EsmFile::([A-Za-z0-9_]+)\s*\(")
    for match in pattern.finditer(cpp):
        opening = cpp.find("{", match.end())
        if opening < 0:
            continue
        try:
            closing = close_bracket(cpp, opening)
        except ValueError:
            continue
        body = cpp[opening:closing + 1]
        record_types = sorted(set(re.findall(r'(?:record|info|r|child|base|land|ltex|txst|soun|wrld|cell|race)\s*(?:->|\.)\s*type\s*[!=]=\s*"([A-Z0-9_]{4})"', body)))
        tags = sorted(set(re.findall(
            r'\b(?!(?:record|info|r|child|base|land|ltex|txst|soun|wrld|cell|race)\.)[A-Za-z_][A-Za-z0-9_]*\.type\s*[!=]=\s*"([A-Z0-9_]{4})"',
            body,
        )))
        streams: dict[str, list[str]] = {}
        # A method may parse a placed record and then parse its base form;
        # keep their loops separate so the audit does not mislabel MODL as a
        # REFR field simply because get_cell_references also reads it.
        loop_pattern = re.compile(r"for\s*\(\s*const\s+auto\s*&\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\{")
        for loop in loop_pattern.finditer(body):
            try:
                loop_end = close_bracket(body, loop.end() - 1)
            except ValueError:
                continue
            loop_var, stream = loop.group(1), loop.group(2)
            loop_body = body[loop.end():loop_end]
            stream_tags = sorted(set(re.findall(
                rf'\b{re.escape(loop_var)}\.type\s*[!=]=\s*"([A-Z0-9_]+)"', loop_body,
            )))
            if stream_tags:
                streams[stream] = stream_tags
        if record_types or tags:
            out[match.group(1)] = {
                "record_types": record_types,
                "subrecord_tags": tags,
                "subrecord_tags_by_stream": streams,
            }
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("definitions", type=Path, help="path to wbDefinitionsFNV.pas")
    parser.add_argument("--cpp", type=Path, help="optional EsmFile implementation for decoder evidence")
    parser.add_argument("--out", type=Path, required=True, help="JSON schema destination")
    args = parser.parse_args()

    original = args.definitions.read_text(encoding="utf-8-sig")
    source = scrub_comments(original)
    definitions = assigned_definitions(source)
    definitions.update(result_definitions(source))
    records = {}
    for tag, display, expression, offset in extract_records(source):
        fields, opaque = schema_for_record(expression, offset, source, definitions)
        records[tag] = {
            "name": display,
            "source_line": line_of(source, offset),
            "subrecords": fields,
            "opaque_helpers": opaque,
        }

    document: dict = {
        "source": str(args.definitions),
        "format": "xedit-fnv-esm-schema-v1",
        "notes": [
            "This inventory is extracted from xEdit's Delphi definition DSL; it is not a complete executable Delphi interpretation.",
            "opaque_helpers are wb symbols this extractor did not expand. They can be imported field helpers or non-layout callbacks; inspect them before treating a record inventory as exhaustive.",
            "Subrecord presence in xEdit describes valid authored data, not a requirement that the current engine decode it.",
        ],
        "records": dict(sorted(records.items())),
    }
    if args.cpp:
        document["esm_file_static_evidence"] = cpp_strings_by_method(args.cpp.read_text(encoding="utf-8"))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(records)} record schemas to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
