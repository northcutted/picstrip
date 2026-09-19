#!/usr/bin/env python3
"""Audit the string catalogs for gaps a build never reports.

A missing translation is not a compiler error: the app just shows English to a
Japanese user.  This script fails when a catalog has

  * a translatable key without a translation in every supported locale,
  * a translation that is not marked "translated",
  * format specifiers, ${tokens} or Markdown markers that differ from English,
  * `^[...](inflect: true)` markup outside English (the grammar engine ignores
    most languages, so the singular would be shown for every count),
  * plural variations that lack a CLDR category the locale needs.

With --stringsdata it also compares the catalog against what the compiler
extracted from the sources, catching strings that never reached the catalog:

  xcodebuild build -scheme PicStrip -derivedDataPath build/loc SWIFT_EMIT_LOC_STRINGS=YES ...
  scripts/audit_xcstrings.py --stringsdata build/loc

Usage: scripts/audit_xcstrings.py [--stringsdata DIR] [catalog ...]
"""
import argparse
import glob
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

DEFAULT_CATALOGS = [
    'PicStrip/Localizable.xcstrings',
    'PicStrip/AppShortcuts.xcstrings',
    'PicStrip/InfoPlist.xcstrings',
    'PicStripShareExtension/InfoPlist.xcstrings',
]

LOCALES = ['ar', 'de', 'es', 'fr', 'it', 'ja', 'ko', 'nl', 'pl', 'pt-BR', 'pt-PT', 'sv', 'tr', 'zh-Hans', 'zh-Hant']

# CLDR cardinal categories a plural variation must provide.
PLURAL_CATEGORIES = {
    'ar': {'zero', 'one', 'two', 'few', 'many', 'other'},
    'pl': {'one', 'few', 'many', 'other'},
    'ja': {'other'}, 'ko': {'other'}, 'zh-Hans': {'other'}, 'zh-Hant': {'other'},
}
DEFAULT_CATEGORIES = {'one', 'other'}

SPEC = re.compile(r'%(?:(\d+)\$)?(lld|ld|d|@|f|\.\d+f)')
TOKEN = re.compile(r'\$\{[A-Za-z]+\}')
INFLECT = re.compile(r'\^\[(.*?)\]\(inflect: true\)')


def specifiers(text):
    """Sorted [(position, type)]; None when positional and sequential styles are mixed."""
    found = SPEC.findall(text.replace('%%', ''))
    if any(pos for pos, _ in found) and not all(pos for pos, _ in found):
        return None
    return sorted((int(pos) if pos else index, kind) for index, (pos, kind) in enumerate(found, 1))


def unit_value(node):
    return node.get('stringUnit', {}).get('value')


def flatten(localization):
    """Every concrete string a localization can produce, with its plural category (or None)
    and whether it is a substitution fragment."""
    out = []
    if 'stringUnit' in localization:
        out.append((None, False, localization['stringUnit']))
    for category, node in localization.get('variations', {}).get('plural', {}).items():
        out.append((category, False, node['stringUnit']))
    for substitution in localization.get('substitutions', {}).values():
        for category, node in substitution.get('variations', {}).get('plural', {}).items():
            out.append((category, True, node['stringUnit']))
    return out


def audit_catalog(path):
    errors = []
    catalog = json.loads(path.read_text(encoding='utf-8'))
    source = catalog.get('sourceLanguage', 'en')
    for key, entry in catalog['strings'].items():
        if entry.get('shouldTranslate') is False:
            continue
        label = f'{path.name}: {key[:60]!r}'
        localizations = entry.get('localizations', {})
        english = unit_value(localizations.get(source, {})) or key
        plain_english = INFLECT.sub(lambda m: m.group(1), english)

        for locale in LOCALES:
            localization = localizations.get(locale)
            if localization is None:
                errors.append(f'{label}: no {locale} translation')
                continue

            for group in [localization.get('variations', {}).get('plural')] + [
                s.get('variations', {}).get('plural') for s in localization.get('substitutions', {}).values()
            ]:
                if group is None:
                    continue
                needed = PLURAL_CATEGORIES.get(locale, DEFAULT_CATEGORIES)
                if not needed <= set(group):
                    errors.append(f'{label}: {locale} plural lacks {sorted(needed - set(group))}')

            for category, is_fragment, string_unit in flatten(localization):
                value = string_unit.get('value', '')
                where = f'{label} [{locale}{"/" + category if category else ""}]'
                if string_unit.get('state') != 'translated':
                    errors.append(f'{where}: state is {string_unit.get("state")!r}')
                if not value.strip():
                    errors.append(f'{where}: empty')
                if 'inflect: true' in value:
                    errors.append(f'{where}: inflect markup only works in English — use plural variations')
                if is_fragment or '%#@' in value:
                    continue   # argument numbers are rewritten by the substitution
                if sorted(TOKEN.findall(value)) != sorted(TOKEN.findall(english)):
                    errors.append(f'{where}: ${{token}} mismatch')
                if value.count('**') != english.count('**'):
                    errors.append(f'{where}: Markdown ** mismatch')
                got, want = specifiers(value), specifiers(plain_english)
                spelled_out = locale == 'ar' and category in ('zero', 'one', 'two') and got == []
                if got is None:
                    errors.append(f'{where}: mixes %@ and %1$@ styles')
                elif got != want and not spelled_out:
                    errors.append(f'{where}: specifiers {got} != English {want}')
    return errors


def audit_extraction(directory):
    """Keys the compiler extracted vs. keys in Localizable.xcstrings."""
    extracted = set()
    for path in glob.glob(f'{directory}/**/*.stringsdata', recursive=True):
        if 'GeneratedStringSymbols' in path:
            continue
        data = json.loads(Path(path).read_text(encoding='utf-8'))
        if 'GeneratedStringSymbols' in data.get('source', ''):
            continue
        extracted.update(item['key'] for item in data.get('tables', {}).get('Localizable', []))
    if not extracted:
        return [f'no .stringsdata under {directory} — build with SWIFT_EMIT_LOC_STRINGS=YES']
    catalog = json.loads((ROOT / DEFAULT_CATALOGS[0]).read_text(encoding='utf-8'))['strings']
    errors = [f'in code but not in the catalog: {key!r}' for key in sorted(extracted - set(catalog))]
    errors += [
        f'in the catalog but no longer in code: {key!r}'
        for key in sorted(set(catalog) - extracted)
        if catalog[key].get('shouldTranslate') is not False
    ]
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('catalogs', nargs='*', default=DEFAULT_CATALOGS)
    parser.add_argument('--stringsdata', metavar='DIR', help='derived data of a SWIFT_EMIT_LOC_STRINGS=YES build')
    args = parser.parse_args()

    errors = []
    for catalog in args.catalogs:
        errors += audit_catalog(ROOT / catalog)
    if args.stringsdata:
        errors += audit_extraction(args.stringsdata)

    for line in errors:
        print(line)
    if errors:
        print(f'\n{len(errors)} string catalog problem(s).')
        return 1
    print('String catalog audit passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
