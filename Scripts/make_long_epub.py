"""生成性能验收用的长篇中文 EPUB（确定性、无版权内容）。

用法：python3 Scripts/make_long_epub.py <输出路径> [章数，默认 30] [每章字数，默认 15000]
正文由固定词表按固定随机种子组句，只用于排版、导入、索引与检索的规模测试。
"""
import random
import sys
import zipfile

SUBJECTS = ["读者", "作者", "学生", "老师", "研究者", "图书管理员", "旅行者", "工程师", "园丁", "记录员"]
VERBS = ["注意到", "反复思考", "写下", "讨论", "比较", "怀疑", "整理", "复述", "追问", "重新阅读"]
OBJECTS = ["段落之间的联系", "记忆随时间的衰减", "间隔复习的节奏", "笔记与原文的差别", "一个反例", "章节的结构",
           "概念之间的边界", "论证中的假设", "故事里的转折", "数据背后的来源"]
TAILS = ["，并把结论记在页边。", "，随后发现之前的理解并不完整。", "，于是决定第二天再回来看。", "，这让整个问题变得清楚了一些。",
         "，但仍然留下了一个没有回答的疑问。", "，并试着用自己的话解释给别人听。", "，最后把它和上一章的内容放在一起。"]


def paragraph(rng, target):
    out = ""
    while len(out) < target:
        out += rng.choice(SUBJECTS) + rng.choice(VERBS) + rng.choice(OBJECTS) + rng.choice(TAILS)
    return out


def main():
    path = sys.argv[1]
    chapters = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    per_chapter = int(sys.argv[3]) if len(sys.argv) > 3 else 15000
    rng = random.Random(20261018)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>""", compress_type=zipfile.ZIP_DEFLATED)
        manifest, spine, nav = [], [], []
        for i in range(1, chapters + 1):
            body, n = [], 0
            while n < per_chapter:
                p = paragraph(rng, 180)
                body.append(f"<p>{p}</p>")
                n += len(p)
            title = f"第{i}章 长篇性能样本"
            z.writestr(f"OEBPS/ch{i:02d}.xhtml", f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head>
<body><h1>{title}</h1>{''.join(body)}</body></html>""", compress_type=zipfile.ZIP_DEFLATED)
            manifest.append(f'<item id="c{i}" href="ch{i:02d}.xhtml" media-type="application/xhtml+xml"/>')
            spine.append(f'<itemref idref="c{i}"/>')
            nav.append(f'<li><a href="ch{i:02d}.xhtml">{title}</a></li>')
        z.writestr("OEBPS/nav.xhtml", f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head>
<body><nav epub:type="toc"><ol>{''.join(nav)}</ol></nav></body></html>""", compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">thoughttrail-perf-long-zh</dc:identifier>
    <dc:title>长篇性能样本</dc:title><dc:creator>ThoughtTrail</dc:creator><dc:language>zh-CN</dc:language>
  </metadata>
  <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>{''.join(manifest)}</manifest>
  <spine>{''.join(spine)}</spine>
</package>""", compress_type=zipfile.ZIP_DEFLATED)


main()
