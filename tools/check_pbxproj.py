#!/usr/bin/env python3
'''Structural sanity check for Madeira.xcodeproj after an automated edit.

Xcode will not tell you a project file is malformed until you open it, and this
box has no Xcode, so this checks the things that actually break: unbalanced
braces and parens, duplicate object IDs, references to object IDs that are never
defined, and -- the one that cost a run -- build inputs that point at nothing.

The last check exists because of a real failure. JitOnboardingView.swift was
added to the target as a child of the application group instead of the Variant
group it lives in, so its path resolved to app/Madeira/JitOnboardingView.swift
rather than app/Madeira/Variant/JitOnboardingView.swift. Every structural check
here passed, the workflow spent twenty-four minutes compiling the native chain,
and xcodebuild then failed with a missing build input in both variants. Twenty
seconds here is worth that many minutes.

Scope of that check: the Sources and Resources phases only. Every input in them
is a tracked file, so a missing one is always a defect. The Frameworks phase is
deliberately excluded -- it names archives that earlier steps of the same job
build (libntdll_unix.a, libFEXCore.a, ...) and SDK paths such as
System/Library/Frameworks/Metal.framework, none of which exist in a fresh
checkout, and a check that has to know which of those are legitimate is a check
that gets silenced rather than fixed.

Usage: python3 tools/check_pbxproj.py [path/to/project.pbxproj]
       (default: app/Madeira.xcodeproj/project.pbxproj; exit 0 = sound)

The optional path exists so the check can be pointed at a historical revision to
confirm it still catches what it was written for. Keep such a copy inside
app/Madeira.xcodeproj/, since relative paths resolve against that directory.
'''

from __future__ import annotations

import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / 'app' / 'Madeira.xcodeproj' / 'project.pbxproj'

# This file is deliberately free of regexes. The object format is line-oriented
# and a scanner says what it means; a pattern with escaped tabs and quotes in it
# is both harder to read and easy to get subtly wrong.
TAB = chr(9)
NL = chr(10)
QUOTE = chr(34)
BSLASH = chr(92)
HEX = '0123456789ABCDEF'

TERM = TAB + TAB + '};'
CLOSE = '};'

OPEN_GROUPS = {'PBXGroup', 'PBXVariantGroup'}
CHECKED_PHASES = {'PBXSourcesBuildPhase', 'PBXResourcesBuildPhase'}

# Inputs that are legitimately absent from a clean checkout. Only one, and for a
# documented reason: the Microsoft VC++ runtime DLLs cannot be redistributed, so
# the workflow creates that directory when the secret that carries them is not
# set, and an empty directory satisfies the folder reference.
ALLOWED_ABSENT = {'Madeira/x86_64-vcruntime'}


def blanked(raw: str) -> str:
    '''raw with comment bodies and string bodies replaced by spaces.

    Brace and paren counting has to ignore both: the project file carries build
    phases whose shell scripts are full of braces, and comments that mention
    them. Length is preserved so offsets stay comparable while debugging.
    '''
    out = []
    i, n = 0, len(raw)
    while i < n:
        c = raw[i]
        nxt = raw[i + 1] if i + 1 < n else ''
        if c == '/' and nxt == '*':
            j = raw.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(' ' * (j - i))
            i = j
        elif c == '/' and nxt == '/':
            j = raw.find(NL, i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif c == QUOTE:
            j = i + 1
            while j < n and raw[j] != QUOTE:
                j += 2 if raw[j] == BSLASH else 1
            j = min(j + 1, n)
            out.append(QUOTE + ' ' * (j - i - 1))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def object_head(line: str):
    '''(id, text after the opening brace) for a line that opens an object.'''
    if not line.startswith(TAB + TAB):
        return None
    rest = line[2:]
    oid = rest[:8]
    if len(oid) != 8 or any(ch not in HEX for ch in oid):
        return None
    cut = rest.find('= {')
    if cut < 0:
        return None
    return oid, rest[cut + 3 :]


def objects(raw: str) -> dict:
    '''id -> object body.

    The build-file section writes one-line objects (A1000001 ... = {isa =
    PBXBuildFile; ...; };) and the group section writes multi-line ones, so a
    scan that only looks for the terminator swallows every one-line object it
    passes and ends up reporting a tree with no project object in it at all.
    '''
    lines = raw.split(NL)
    found = {}
    i = 0
    while i < len(lines):
        head = object_head(lines[i])
        if head is None:
            i += 1
            continue
        oid, rest = head
        if CLOSE in rest:
            found[oid] = rest
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j] != TERM:
            j += 1
        found[oid] = NL.join(lines[i + 1 : j])
        i = j + 1
    return found


def field(body: str, key: str):
    '''The value of `key = value;` in the body, quotes and comment stripped.

    A search within each line rather than a prefix match on it, because the
    build-file section writes whole objects on one line: `isa = PBXBuildFile;
    fileRef = A2000001 ...; };` puts the key we want in the middle of a line.
    '''
    needle = key + ' = '
    for line in body.split(NL):
        s = line.strip()
        idx = s.find(needle)
        if idx < 0:
            continue
        if idx > 0 and (s[idx - 1].isalnum() or s[idx - 1] == '_'):
            continue
        v = s[idx + len(needle) :].strip()
        cut = v.find(';')
        if cut >= 0:
            v = v[:cut].strip()
        comment = v.find(' /*')
        if comment >= 0:
            v = v[:comment].strip()
        if len(v) >= 2 and v[0] == QUOTE and v[-1] == QUOTE:
            v = v[1:-1]
        return v
    return None


def list_ids(body: str, key: str):
    '''The 8-character IDs inside a `key = ( ... );` block.'''
    ids, inside = [], False
    for line in body.split(NL):
        s = line.strip()
        if not inside:
            inside = s.startswith(key + ' = (')
            if inside and s[len(key) + 4 :].strip().startswith(');'):
                return ids
            continue
        if s.startswith(');'):
            break
        token = s.split(' ', 1)[0]
        if len(token) == 8 and all(ch in HEX for ch in token):
            ids.append(token)
    return ids


def defined_ids(raw: str):
    '''Object IDs declared at the start of a two-tab-indented line.'''
    ids = []
    for line in raw.split(NL):
        if line.startswith(TAB + TAB):
            rest = line[2:]
            if len(rest) > 8 and rest[8] == ' ' and all(ch in HEX for ch in rest[:8]):
                ids.append(rest[:8])
    return ids


def hex_tokens(text: str):
    '''Every run of exactly eight uppercase hex characters.'''
    tokens, cur = [], []
    for ch in text:
        if ch in HEX:
            cur.append(ch)
            continue
        if len(cur) == 8:
            tokens.append(''.join(cur))
        cur = []
    if len(cur) == 8:
        tokens.append(''.join(cur))
    return tokens


def build_input_paths(raw: str):
    '''Resolve the Sources and Resources inputs to paths relative to app/.

    Returns (paths, unplaceable_ids). A reference that cannot be placed in the
    group tree is reported rather than skipped: the tree is the only thing that
    turns a path into a real file, so failing to walk it means the answer is
    unknown, not that the input is fine.
    '''
    objs = objects(raw)

    wanted = []
    for body in objs.values():
        if field(body, 'isa') in CHECKED_PHASES:
            wanted += list_ids(body, 'files')

    group_path = {}
    for oid, body in objs.items():
        if field(body, 'isa') in OPEN_GROUPS:
            group_path[oid] = field(body, 'path') or ''

    main = None
    for body in objs.values():
        if field(body, 'isa') == 'PBXProject':
            main = field(body, 'mainGroup')
    if main is None:
        return [], list(wanted)

    resolved = {}
    stack, seen = [(main, '')], set()
    while stack:
        oid, prefix = stack.pop()
        if oid in seen:
            continue
        seen.add(oid)
        body = objs.get(oid)
        if body is None:
            continue
        name = group_path.get(oid) or ''
        if not prefix:
            here = name
        elif not name:
            here = prefix
        else:
            here = prefix + '/' + name
        kids = list_ids(body, 'children')
        if kids:
            for kid in kids:
                stack.append((kid, here))
            continue
        path = field(body, 'path')
        if path:
            resolved[oid] = here + '/' + path if here else path

    inputs, unplaceable = [], []
    for oid in wanted:
        body = objs.get(oid)
        ref = field(body, 'fileRef') if body else None
        rel = resolved.get(ref) if ref else None
        if rel is None:
            unplaceable.append(oid)
        else:
            inputs.append(rel)
    return inputs, unplaceable


def main() -> int:
    project = Path(sys.argv[1]) if len(sys.argv) > 1 else PROJECT
    raw = project.read_text(encoding='utf-8')

    defined = defined_ids(raw)
    duplicates = sorted({i for i in defined if defined.count(i) > 1})

    stripped = blanked(raw)
    n_braces = stripped.count('{')
    n_closes = stripped.count('}')
    n_parens = stripped.count('(')
    n_paren_closes = stripped.count(')')
    braces_ok = n_braces == n_closes
    parens_ok = n_parens == n_paren_closes

    known = set(defined)
    # Dangling IDs are reported as information, not a failure: an 8-hex-character
    # string can also occur incidentally (a truncated SHA, a hex constant), and a
    # false positive here is worse than a missed one. Braces, parens, duplicates
    # and missing inputs are the checks that catch a broken edit.
    dangling = sorted({t for t in hex_tokens(raw) if t not in known})

    inputs, unplaceable = build_input_paths(raw)
    # Paths are relative to the project directory's parent, which is app/,
    # derived from the file under test so a historical copy resolves against the
    # same tree instead of an empty one.
    app_root = project.resolve().parent.parent
    missing = sorted(
        {rel for rel in inputs if not (app_root / rel).exists() and rel not in ALLOWED_ABSENT}
    )

    print('objects defined :', len(defined))
    print('braces balanced :', braces_ok, '(%d/%d)' % (n_braces, n_closes))
    print('parens balanced :', parens_ok, '(%d/%d)' % (n_parens, n_paren_closes))
    print('duplicate ids   :', duplicates if duplicates else 'none')
    print('dangling refs   :', dangling if dangling else 'none')
    print('build inputs    : %d resolved, %d unplaceable' % (len(inputs), len(unplaceable)))
    print('inputs missing  :', missing if missing else 'none')

    if not defined:
        print('RESULT: PROBLEM (no object IDs matched - the ID format assumption is wrong)')
        return 1
    if not inputs:
        print('RESULT: PROBLEM (no build inputs found - the parse assumption is wrong)')
        return 1
    ok = braces_ok and parens_ok and not duplicates and not missing
    print('RESULT:', 'OK' if ok else 'PROBLEM')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
