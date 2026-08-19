#!/usr/bin/env python3
"""
genlist.py - 扫描目录生成预加载文件列表 filelist.json

用法:
    python script/genlist.py                          # 扫描当前目录
    python script/genlist.py -d out/wasm/Debug        # 指定目录
    python script/genlist.py -e xp3 dll tpm tjs bin   # 自定义扩展名

输出: filelist.json（纯文件名数组，路径包含子目录如 plugin/xxx.dll）
"""

import os
import json
import argparse
import fnmatch


def scan(target_dir, extensions):
    files = []
    target_dir = os.path.abspath(target_dir)

    for root, dirs, fnames in os.walk(target_dir):
        for fname in fnames:
            # 检查扩展名是否匹配
            if any(fnmatch.fnmatch(fname, f"*.{ext.lstrip('.')}") for ext in extensions):
                full = os.path.join(root, fname)
                rel = os.path.relpath(full, target_dir).replace('\\', '/')
                # 排除引擎文件
                if not rel.startswith('krkrsdl3.'):
                    files.append(rel)

    files.sort()
    return files


def main():
    parser = argparse.ArgumentParser(description='生成预加载文件列表')
    parser.add_argument('-d', '--dir', default='.',
                        help='扫描的目标目录（默认当前目录）')
    parser.add_argument('-o', '--output', default='filelist.json',
                        help='输出文件名（默认 filelist.json）')
    parser.add_argument('-e', '--ext', nargs='*',
                        default=['xp3', 'dll', 'tpm', 'tjs'],
                        help='要包含的文件扩展名（默认 xp3 dll tpm tjs）')
    args = parser.parse_args()

    files = scan(args.dir, args.ext)

    out_path = os.path.join(args.dir, args.output)
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(files, f, ensure_ascii=False)

    print(f"Generated {len(files)} files in {out_path}")
    for name in files:
        print(f"  {name}")


if __name__ == '__main__':
    main()
