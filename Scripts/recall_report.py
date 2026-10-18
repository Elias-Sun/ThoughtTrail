"""汇总真机本地召回采样（recall.json）：P50/P95（最近秩法）、冷查询、建库、索引体积与内存。"""
import json
import math
import sys


def pct(values, p):
    s = sorted(values)
    return s[max(0, math.ceil(p / 100 * len(s)) - 1)]


def main():
    data = json.load(open(sys.argv[1]))
    env, commit = sys.argv[2], sys.argv[3]
    print("# 真机本地召回（10.1：5,000 子块；20,000 子块规模检查）\n")
    print(f"- 设备：{env}；应用内记录：{data['device']}；提交：{commit}；Release 构建")
    print("- 方法：每个规模在独立 SQLite 文件中写入合成子块（约 300 字/子块、4 子块/父块，与默认切块上限 320/1200 一致）、"
          "FTS5 全文索引与 1024 维向量（`text-embedding-v4` 默认维度），用正式 `HybridRetriever`"
          "（词法 BM25 + 向量 + RRF + 父块扩展，无重排）在全书范围检索；查询向量由本地哈希生成，**不含网络 Embedding/Rerank**。"
          "首个查询包含从 SQLite 读取并解码全部向量（冷读索引），单独列出；之后 30 次为热查询。临时库在测完后删除。\n")
    print("| 规模 | 次数 | P50 (ms) | P95 (ms) | 最大 (ms) | 冷读首查 (ms) | 目标 P95 | 对照 | 建库 (s) | 索引体积 (MB) | 内存：检索前 / 检索峰值 (MB) |")
    print("|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---|")
    for r in data["runs"]:
        n = r["child_chunks"]
        if "error" in r:
            print(f"| {n:,} 子块 | — | — | — | — | — | — | 失败：{r['error']} | — | — | — |")
            continue
        w = r["warm_ms"]
        p95 = pct(w, 95)
        target, verdict = ("≤500", "达到" if p95 <= 500 else "未达到") if n == 5000 else ("（规模检查）", "—")
        m = r["memory_mb"]
        print(f"| {n:,} 子块（{r['parent_chunks']:,} 父块，{r['text_chars'] / 1e6:.2f} M 字） | {len(w)} | {pct(w, 50):.1f} | {p95:.1f} | {max(w):.1f} | "
              f"{r['cold_first_query_ms']:.1f} | {target} | {verdict} | {r['build_ms'] / 1000:.1f} | {r['index_bytes'] / 1048576:.1f} | "
              f"{m['before_queries']:.1f} / {m['peak_during_queries']:.1f} |")
    print()
    for r in data["runs"]:
        if "error" not in r:
            per = r["results_per_query"]
            print(f"- {r['child_chunks']:,} 子块：每次查询返回 {min(per)}～{max(per)} 个结果单元（冷查询 {r['cold_query_results']} 个），确认检索确实命中。")
    for r in data["runs"]:
        if "error" not in r and "wal_bytes_before_checkpoint" in r:
            print(f"- {r['child_chunks']:,} 子块：检查点前 WAL {r['wal_bytes_before_checkpoint'] / 1048576:.1f} MB，检查点后 {r['wal_bytes_after_checkpoint'] / 1048576:.1f} MB。")
    print("- 内存为进程 phys_footprint；索引体积为 WAL 检查点（TRUNCATE）后的 SQLite 主库文件大小，包含子块与父块正文、FTS5 索引与 1024 维向量。")


main()
