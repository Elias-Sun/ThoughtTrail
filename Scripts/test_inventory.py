#!/usr/bin/env python3
"""从 Swift Testing 源码与运行日志生成唯一用例清单：模块、套件、用例名、需求 ID、结果。
用法：test_inventory.py <输出目录> <运行日志> <清单.md>"""
import os, re, sys, collections

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out_dir, log_path, md_path = sys.argv[1], sys.argv[2], sys.argv[3]
log = open(log_path, encoding="utf-8", errors="ignore").read()

passed = set(re.findall(r'✔ Test "(.+?)" passed', log))
failed = set(re.findall(r'✘ Test "(.+?)" (?:failed|recorded)', log))
skipped = set(re.findall(r'➜ Test "(.+?)" skipped', log))

tests = []
for target in sorted(os.listdir(os.path.join(root, "Tests"))):
    tdir = os.path.join(root, "Tests", target)
    if not os.path.isdir(tdir) or target == "TestSupport":
        continue
    for dirpath, _, files in os.walk(tdir):
        for f in sorted(files):
            if not f.endswith(".swift"):
                continue
            src = open(os.path.join(dirpath, f), encoding="utf-8").read()
            suite = None
            for line in src.splitlines():
                m = re.search(r'@Suite\("(.+?)"\)', line)
                if m:
                    suite = m.group(1)
                m = re.search(r'@Test\("(.+?)"\)', line)
                if m:
                    name = m.group(1)
                    req = name.split(" ")[0]
                    tests.append((target, suite or "-", f, name, req))

names = [t[3] for t in tests]
dupes = [n for n, c in collections.Counter(names).items() if c > 1]
by_target = collections.Counter(t[0] for t in tests)
by_req = collections.defaultdict(list)
for t in tests:
    for r in re.split(r"[/、,]", t[4]):
        by_req[r].append(t[3])

def status(n):
    if n in failed: return "失败"
    if n in skipped: return "跳过"
    if n in passed: return "通过"
    return "未执行"

counts = collections.Counter(status(t[3]) for t in tests)
with open(md_path, "w", encoding="utf-8") as fh:
    fh.write("# 核心自动化测试清单\n\n")
    fh.write(f"- 源码中声明的唯一用例：**{len(tests)}**（重名 {len(dupes)} 个）\n")
    fh.write(f"- 本次运行：通过 {counts['通过']}，失败 {counts['失败']}，跳过 {counts['跳过']}，未执行 {counts['未执行']}\n")
    fh.write(f"- 原始日志：`{os.path.basename(log_path)}`\n\n")
    fh.write("## 按测试 target 统计\n\n| Target | 用例数 |\n|---|---:|\n")
    for k, v in sorted(by_target.items()):
        fh.write(f"| {k} | {v} |\n")
    fh.write("\n## 需求 → 用例数\n\n| 需求 | 用例数 |\n|---|---:|\n")
    for k in sorted(by_req):
        fh.write(f"| {k} | {len(by_req[k])} |\n")
    fh.write("\n## 全部用例\n\n| # | Target | 套件 | 用例 | 结果 |\n|---:|---|---|---|---|\n")
    for i, t in enumerate(tests, 1):
        fh.write(f"| {i} | {t[0]} | {t[1]} | {t[3]} | {status(t[3])} |\n")
print(f"唯一用例 {len(tests)}；通过 {counts['通过']}，失败 {counts['失败']}，跳过 {counts['跳过']}，未执行 {counts['未执行']}；重名 {len(dupes)}")
if dupes:
    print("重名用例：", dupes)
