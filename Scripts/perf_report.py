"""汇总 perf-sim.sh 的原始采样：P50/P95（最近秩法）与 10.1 目标对照。"""
import json
import math
import sys
from pathlib import Path


def pct(values, p):
    s = sorted(values)
    return s[max(0, math.ceil(p / 100 * len(s)) - 1)]


def main():
    out, env, commit = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    device = len(sys.argv) > 4 and sys.argv[4] == "device"
    suite = json.loads((out / "suite.json").read_text())
    cold = [json.loads(l) for l in (out / "coldstart.jsonl").read_text().splitlines() if l.strip()]
    rows = []
    if not device:
        # 宿主时钟与模拟器一致时才有意义；真机时钟与宿主不同步，不报告此项
        rows.append(("冷启动至书库可操作（宿主发起启动 → 就绪）", [c["launch_to_ready_ms"] for c in cold], 3000))
    rows += [
        ("冷启动（进程创建 → 就绪）", [c["process_to_ready_ms"] for c in cold], 3000),
        ("已导入书籍重新打开（读库 + 定位 + 首屏排版）", suite["reopen_ms"], 2000),
        ("批注本地保存", suite["highlight_save_ms"], 300),
        ("反思本地保存（更新草稿 + 提交）", suite["reflection_save_ms"], 300),
        ("取消后退出等待状态", suite["cancel_ms"], 500),
    ]
    scale = f"《{suite['book']}》"
    if "book_chapters" in suite:
        scale += f"，{suite['book_chapters']} 章、{suite['book_utf16']:,} UTF-16 单元；首章 {suite['chapter_utf16']:,}"
    else:
        scale += f"（当前章 {suite['chapter_utf16']} UTF-16 单元）"
    if device:
        print("# 真机 Release 本地时延（D-13 采样）\n")
        print(f"- 设备：{env}；应用内记录：{suite.get('device', '')}")
        print(f"- 提交：{commit}；Release 构建（开发签名）；确定性模型（`-demo`，本地操作与正式模式同一代码路径）；网络：本地操作不访问网络")
        print(f"- 数据：{scale}" + (f"；正式导入（解析 + 词法索引）耗时 {suite['import_ms']:.0f} ms" if suite.get("import_ms", -1) >= 0 else ""))
        print("- 冷/热状态：冷启动为进程冷启动（每次结束旧进程后由 devicectl 启动），系统文件缓存可能是热的；重开/保存/取消在同一进程内连续采样（热）。")
        print("- 冷启动从进程创建算起（设备本地时钟），不含用户点击图标到进程创建之间的系统开销。\n")
        print("| 指标 | 次数 | P50 (ms) | P95 (ms) | 最大 (ms) | D-13 / 10.1 目标 P95 | 对照 |")
    else:
        print("# 模拟器本地时延采样——模拟器参考值，不作为设备验收 D-13 依据\n")
        print(f"- 环境：{env}")
        print(f"- 提交：{commit}；Release 构建；确定性模型（`-demo`）；数据：{scale}")
        print("- 冷启动为进程冷启动（每次先结束进程），磁盘缓存是热的；模拟器运行在 Mac 上，CPU/IO 与 iPhone 不同，**不作为 10.1 验收数据**。\n")
        print("**模拟器参考值，不作为设备验收 D-13 依据**\n")
        print("| 指标（模拟器参考值，不作为设备验收 D-13 依据） | 次数 | P50 (ms) | P95 (ms) | 最大 (ms) | 10.1 目标 P95 | 对照 |")
    print("|---|---:|---:|---:|---:|---:|---|")
    for name, v, target in rows:
        if not v:
            print(f"| {name} | 0 | — | — | — | ≤{target} | 无数据 |")
            continue
        p95 = pct(v, 95)
        verdict = ("达到" if p95 <= target else "未达到") if device else ("低于目标" if p95 <= target else "超出目标")
        print(f"| {name} | {len(v)} | {pct(v, 50):.1f} | {p95:.1f} | {max(v):.1f} | ≤{target} | {verdict} |")
    print(f"\n- 取消后迟到响应改变界面状态的次数：**{suite['cancel_late_state_changes']}** / {len(suite['cancel_ms'])}"
          "（取消后再等待 1.7 秒，检查等待状态、草稿文本与消息状态均未变化）")


main()
