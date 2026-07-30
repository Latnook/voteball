#!/usr/bin/env bash
# Asserts all three DICTIONARY language objects in i18n.js carry identical key sets.
# t() returns the key itself on a miss, so a gap renders "familyWelfareState" on the page
# rather than throwing -- nothing else in the repo catches that.
set -euo pipefail
I18N="${1:-$(dirname "$0")/../../services/frontend/i18n.js}"

python3 - "$I18N" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
body = src.split('const DICTIONARY = {', 1)[1]

blocks, depth, cur, lang = {}, 0, [], None
for line in body.split('\n'):
    m = re.match(r'\s{2}([a-z]{2}): \{\s*$', line)
    if m and depth == 0:
        lang, depth, cur = m.group(1), 1, []
        continue
    if depth:
        if re.match(r'\s{2}\},?\s*$', line):
            blocks[lang], depth = cur, 0
            continue
        cur.append(line)

keys = {l: set(re.findall(r"^\s*([A-Za-z0-9_]+):", '\n'.join(v), re.M)) for l, v in blocks.items()}
print(f"languages: {sorted(keys)}  sizes: { {l: len(k) for l, k in keys.items()} }")

fail = False

expected_langs = {'en', 'he', 'ru'}
if set(keys) != expected_langs:
    print(f"  PARSER FAILURE: expected language blocks {sorted(expected_langs)}, found {sorted(keys)}")
    sys.exit(1)

for lang, k in keys.items():
    if not k:
        print(f"  PARSER FAILURE: {lang} block parsed but yielded zero keys")
        fail = True
if fail:
    sys.exit(1)

base = keys.get('en', set())
for lang, k in sorted(keys.items()):
    missing, extra = sorted(base - k), sorted(k - base)
    if missing:
        print(f"  {lang}: MISSING {missing}"); fail = True
    if extra:
        print(f"  {lang}: EXTRA {extra}"); fail = True

cyrillic = re.compile(r'[Ѐ-ӿ]')
latin = re.compile(r'[A-Za-z]')
for line in blocks.get('ru', []):
    m = re.match(r"\s*(family[A-Za-z0-9_]*): '([^']*)'", line)
    if m and cyrillic.search(m.group(2)) and latin.search(m.group(2)):
        print(f"  ru: MIXED SCRIPT in {m.group(1)}: {m.group(2)!r}"); fail = True

sys.exit(1 if fail else 0)
PY
echo "i18n parity OK"
