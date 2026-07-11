#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Apply Traditional-Chinese translations onto an upstream winutil checkout.

Three mechanisms:
 1. config/*.json  -> field-scoped dictionary replacement (config-dict.json)
 2. xaml/inputXML.xaml -> difflib-derived exact {old,new} string pairs
 3. functions/*.ps1 -> difflib-derived exact {old,new} string pairs per file

All reads/writes are UTF-8; writes are UTF-8 WITHOUT BOM, LF newlines preserved
as produced by the replacement (we do not normalise newlines beyond what the
source pairs carry).
"""
import argparse, io, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

# file -> list of fields whose English value should be dict-translated
CONFIG_FIELDS = {
    'applications.json':   ['description', 'category'],
    'tweaks.json':         ['Content', 'Description', 'category'],
    'feature.json':        ['Content', 'Description', 'category'],
    'appx.json':           ['Content', 'Description', 'Category'],
    'appnavigation.json':  ['Content', 'Description', 'Category'],
}


def read_text(path):
    # Normalise CRLF/CR -> LF so difflib-derived (LF) pairs match regardless of
    # how the upstream repo was checked out (Windows runners may use autocrlf).
    with io.open(path, encoding='utf-8', newline='') as f:
        return f.read().replace('\r\n', '\n').replace('\r', '\n')


def write_text_no_bom(path, text):
    # utf-8 (no BOM), do not translate newlines
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)


def load_json(path):
    with io.open(path, encoding='utf-8') as f:
        return json.loads(f.read(), strict=False)


def translate_config(root, dict_map):
    applied = 0
    miss_fields = 0
    for fname, fields in CONFIG_FIELDS.items():
        path = os.path.join(root, 'config', fname)
        if not os.path.exists(path):
            print(f'  [config] SKIP missing {fname}')
            continue
        data = load_json(path)

        def walk(node):
            nonlocal applied, miss_fields
            if isinstance(node, dict):
                for k, v in list(node.items()):
                    if k in fields and isinstance(v, str):
                        if v in dict_map:
                            node[k] = dict_map[v]
                            applied += 1
                        else:
                            miss_fields += 1
                    else:
                        walk(v)
            elif isinstance(node, list):
                for item in node:
                    walk(item)

        walk(data)
        # write JSON back, UTF-8 no BOM, keep unicode, 2-space indent (winutil style)
        text = json.dumps(data, ensure_ascii=False, indent=2)
        # winutil json files end with a newline
        write_text_no_bom(path, text + '\n')
    print(f'  [config] applied {applied} field translations; '
          f'{miss_fields} target-field values had no dict entry (English kept)')
    return applied


def translate_pairs_file(path, pairs):
    """Apply ordered {old,new} replacements to a single file. Returns (applied, miss)."""
    raw = read_text(path)
    applied = 0
    miss = 0
    for pr in pairs:
        old = pr['old']
        new = pr['new']
        if old in raw:
            raw = raw.replace(old, new, 1)
            applied += 1
        else:
            miss += 1
    write_text_no_bom(path, raw)
    return applied, miss


def translate_xaml(root):
    pairs = load_json(os.path.join(HERE, 'xaml-pairs.json'))
    path = os.path.join(root, 'xaml', 'inputXML.xaml')
    if not os.path.exists(path):
        print('  [xaml] SKIP missing inputXML.xaml')
        return 0
    applied, miss = translate_pairs_file(path, pairs)
    print(f'  [xaml] applied {applied}/{len(pairs)} pairs; {miss} miss (upstream changed -> English fallback)')
    return applied


def translate_functions(root):
    entries = load_json(os.path.join(HERE, 'functions-pairs.json'))
    total_applied = 0
    total_miss = 0
    total_pairs = 0
    for entry in entries:
        rel = entry['file']
        pairs = entry['pairs']
        total_pairs += len(pairs)
        path = os.path.join(root, rel.replace('/', os.sep))
        if not os.path.exists(path):
            print(f'  [func] SKIP missing {rel}')
            total_miss += len(pairs)
            continue
        applied, miss = translate_pairs_file(path, pairs)
        total_applied += applied
        total_miss += miss
        if miss:
            print(f'  [func] {rel}: {applied}/{len(pairs)} applied, {miss} miss')
    print(f'  [func] applied {total_applied}/{total_pairs} pairs; '
          f'{total_miss} miss (upstream changed -> English fallback)')
    return total_applied


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True, help='upstream winutil checkout root')
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f'ERROR: root not found: {root}', file=sys.stderr)
        sys.exit(1)

    dict_map = load_json(os.path.join(HERE, 'config-dict.json'))
    print(f'Applying translations to: {root}')
    print(f'  dict entries: {len(dict_map)}')
    translate_config(root, dict_map)
    translate_xaml(root)
    translate_functions(root)
    print('Done.')


if __name__ == '__main__':
    main()
