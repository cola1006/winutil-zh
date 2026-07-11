#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate xaml-pairs.json and functions-pairs.json from the winutil-src
working tree (HEAD = English upstream, working tree = Chinese translation).
Uses difflib on a line basis, collecting only 'replace' opcodes."""
import difflib, io, os, subprocess, json, sys

SRC = r"C:\Users\user\AppData\Local\Temp\winutil-src"
OUT = os.path.dirname(os.path.abspath(__file__))

def git_show_head(relpath):
    # relpath uses forward slashes for git
    return subprocess.check_output(
        ['git', '-C', SRC, 'show', 'HEAD:' + relpath]
    ).decode('utf-8')

def gen_pairs(relpath):
    old = git_show_head(relpath)
    with io.open(os.path.join(SRC, relpath.replace('/', os.sep)), encoding='utf-8') as f:
        new = f.read()
    old_lines = old.splitlines(keepends=True)
    new_lines = new.splitlines(keepends=True)
    sm = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    pairs = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'replace':
            o = ''.join(old_lines[i1:i2])
            n = ''.join(new_lines[j1:j2])
            if o != n and o.strip() != '':
                pairs.append({'old': o, 'new': n})
    return pairs

# --- XAML ---
xaml_rel = 'xaml/inputXML.xaml'
xaml_pairs = gen_pairs(xaml_rel)
with io.open(os.path.join(OUT, 'xaml-pairs.json'), 'w', encoding='utf-8', newline='\n') as f:
    json.dump(xaml_pairs, f, ensure_ascii=False, indent=2)
print(f'xaml pairs: {len(xaml_pairs)}')

# --- functions/*.ps1 ---
changed = subprocess.check_output(
    ['git', '-C', SRC, 'diff', '--name-only']
).decode('utf-8').splitlines()
func_files = [p for p in changed if p.startswith('functions/') and p.endswith('.ps1')]
functions = []
total = 0
for relpath in func_files:
    pairs = gen_pairs(relpath)
    total += len(pairs)
    functions.append({'file': relpath, 'pairs': pairs})
    print(f'  {relpath}: {len(pairs)} pairs')
with io.open(os.path.join(OUT, 'functions-pairs.json'), 'w', encoding='utf-8', newline='\n') as f:
    json.dump(functions, f, ensure_ascii=False, indent=2)
print(f'functions total pairs: {total} across {len(functions)} files')
