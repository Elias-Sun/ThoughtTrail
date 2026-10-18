"""汇总 D-14 浸泡：混合操作计数、内存占用曲线（首/末/峰值与后半段斜率）与 Leaks 结论（如有）。"""
import json
import sys
from pathlib import Path


def slope(points):
    n = len(points)
    if n < 2:
        return 0.0
    mx = sum(p[0] for p in points) / n
    my = sum(p[1] for p in points) / n
    den = sum((p[0] - mx) ** 2 for p in points)
    return sum((p[0] - mx) * (p[1] - my) for p in points) / den if den else 0.0


def main():
    out, env, commit = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    summary_path = out / "soak-summary.json"
    samples = [json.loads(l) for l in (out / "soak.jsonl").read_text().splitlines() if l.strip()] if (out / "soak.jsonl").exists() else []
    print("# 真机 30 分钟混合操作浸泡（D-14）\n")
    print(f"- 设备：{env}；提交：{commit}；Release 构建；确定性模型（`-demo`）")
    print("- 方式：同一进程内由应用自身的视图模型循环驱动混合操作（换章排版、记为已读、批注增删、反思提交、讨论完成/取消、备份导出），"
          "**不是手指触控操作**；每 10 秒记录 phys_footprint。\n")
    if not summary_path.exists():
        print("**未生成汇总文件：进程在浸泡结束前退出（可能崩溃），见设备崩溃日志。**")
    else:
        s = json.loads(summary_path.read_text())
        print(f"- 结果：运行 {s['elapsed_s'] / 60:.1f} 分钟，**进程未崩溃**，完成 {s['cycles']} 轮；讨论完成 {s['discussions_completed']} 次、"
              f"取消 {s['cancels']} 次、批注 {s['highlights']} 条、反思 {s['reflections']} 条、备份导出 {s['backups']} 次；操作失败 {s['failures']} 次"
              + (f"（{s['failure_kinds']}）" if s.get('failure_kinds') else "") + "。")
    if samples:
        fp = [(x["t_s"] / 60, x["footprint_mb"]) for x in samples if x["footprint_mb"] >= 0]
        fp = fp[:-1] if len(fp) > 2 else fp  # 最后一个点在关闭阅读器之后
        half = [p for p in fp if p[0] >= fp[-1][0] / 2]
        print(f"- 内存占用：开始 {fp[0][1]:.1f} MB，结束 {fp[-1][1]:.1f} MB，峰值 {max(p[1] for p in fp):.1f} MB；"
              f"后半段线性斜率 {slope(half):+.2f} MB/分钟（{len(fp)} 个采样点）。")
        for m in (1, 5, 10, 15, 20, 25, 30):
            near = min(fp, key=lambda p: abs(p[0] - m))
            if abs(near[0] - m) < 0.5:
                print(f"  - 第 {m} 分钟：{near[1]:.1f} MB")
    leaks = out / "leaks-summary.txt"
    if leaks.exists():
        print(f"- Instruments Leaks（单独运行）：{leaks.read_text().strip()}")
    else:
        print("- Instruments Leaks：未取得结果（见原始目录 xctrace.log）。")


main()
