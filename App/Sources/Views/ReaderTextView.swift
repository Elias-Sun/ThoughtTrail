import SwiftUI
import LibraryCore
import ReaderCore

/// 阅读主题配色。
enum ReaderPalette {
    static func background(_ t: ReaderTheme) -> Color {
        switch t {
        case .light: return Color(red: 1, green: 1, blue: 1)
        case .sepia: return Color(red: 0.97, green: 0.93, blue: 0.84)
        case .dark: return Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }

    static func foreground(_ t: ReaderTheme) -> Color {
        switch t {
        case .light: return Color(red: 0.1, green: 0.1, blue: 0.1)
        case .sepia: return Color(red: 0.27, green: 0.2, blue: 0.13)
        case .dark: return Color(red: 0.86, green: 0.86, blue: 0.84)
        }
    }

    static func highlight(_ c: HighlightColor) -> Color {
        switch c {
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .pink: return .pink
        case .purple: return .purple
        }
    }
}

#if os(iOS)
import UIKit

/// 基于 UITextView 的正文视图：UTF-16 选区与 Locator 区间一致；高亮以背景色渲染；按页滚动翻页。
struct ReaderTextView: UIViewRepresentable {
    let chapter: Chapter
    let highlights: [Annotation]
    let preferences: ReaderPreferences
    @Binding var selection: TextSpan?
    let jump: ReaderModel.JumpRequest?
    let pageCommand: ReaderModel.PageCommand?
    let onVisibleRange: (TextSpan) -> Void
    let onMenuAction: (MenuAction) -> Void
    let onPageBoundary: (Bool) -> Void

    enum MenuAction { case highlight, note, ask, reflect }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = LayoutReportingTextView()
        let coordinator = context.coordinator
        // 首次布局（以及旋转、尺寸变化）后上报可见区间；否则首屏在用户滚动前不会被记为已读
        tv.onLayout = { [weak coordinator] view in coordinator?.reportVisible(view) }
        tv.isEditable = false
        tv.isSelectable = true
        tv.textContainerInset = UIEdgeInsets(top: 20, left: 18, bottom: 40, right: 18)
        tv.delegate = context.coordinator
        tv.accessibilityIdentifier = "reader.text"
        tv.adjustsFontForContentSizeCategory = true
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        let signature = "\(chapter.id)|\(preferences.fontSize)|\(preferences.theme)|\(preferences.lineSpacing)|\(highlights.map { "\($0.id)\($0.color)\($0.note ?? "")" })"
        if signature != c.signature {
            let sameChapter = c.chapterID == chapter.id
            let anchorOffset = sameChapter ? c.topOffset(tv) : 0
            c.signature = signature
            c.chapterID = chapter.id
            tv.attributedText = attributed()
            tv.backgroundColor = UIColor(ReaderPalette.background(preferences.theme))
            tv.layoutIfNeeded()
            // 字号/主题变化后保持当前页首字符可见（READ-03）
            if sameChapter { c.scroll(tv, toOffset: anchorOffset, animated: false) } else { tv.setContentOffset(.zero, animated: false) }
            DispatchQueue.main.async { c.reportVisible(tv) }
        }
        if let jump, jump.id != c.lastJump {
            c.lastJump = jump.id
            DispatchQueue.main.async {
                tv.layoutIfNeeded()
                c.scroll(tv, toOffset: jump.range.start, animated: false)
                if jump.select, !jump.range.isEmpty {
                    tv.selectedRange = NSRange(location: jump.range.start, length: jump.range.length)
                }
                c.reportVisible(tv)
            }
        }
        if let cmd = pageCommand, cmd.id != c.lastPage {
            c.lastPage = cmd.id
            c.turnPage(tv, forward: cmd.forward)
        }
        if selection == nil && tv.selectedRange.length > 0 && c.lastJump == jump?.id && !(jump?.select ?? false) {
            tv.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    func attributed() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = CGFloat(preferences.fontSize * (preferences.lineSpacing - 1))
        style.paragraphSpacing = CGFloat(preferences.fontSize * 0.8)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "PingFangSC-Regular", size: preferences.fontSize)
                                                                  ?? .systemFont(ofSize: preferences.fontSize))
        let s = NSMutableAttributedString(string: chapter.text, attributes: [
            .font: font, .paragraphStyle: style, .foregroundColor: UIColor(ReaderPalette.foreground(preferences.theme)),
        ])
        let length = (chapter.text as NSString).length
        for a in highlights {
            let r = a.locator.range.clamped(toLength: length)
            guard !r.isEmpty else { continue }
            s.addAttribute(.backgroundColor, value: UIColor(ReaderPalette.highlight(a.color)).withAlphaComponent(preferences.theme == .dark ? 0.35 : 0.3),
                           range: NSRange(location: r.start, length: r.length))
            if a.note != nil {
                s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: r.start, length: r.length))
            }
        }
        return s
    }

    /// 在布局完成、尺寸变化时回调的 UITextView。
    final class LayoutReportingTextView: UITextView {
        var onLayout: ((UITextView) -> Void)?
        private var lastSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != lastSize, bounds.height > 0 else { return }
            lastSize = bounds.size
            let callback = onLayout
            DispatchQueue.main.async { [weak self] in if let self { callback?(self) } }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReaderTextView
        var signature = ""
        var chapterID = ""
        var lastJump: UUID?
        var lastPage: UUID?

        init(_ parent: ReaderTextView) { self.parent = parent }

        func offset(_ tv: UITextView, at point: CGPoint) -> Int {
            guard let pos = tv.closestPosition(to: point) else { return 0 }
            return tv.offset(from: tv.beginningOfDocument, to: pos)
        }

        func topOffset(_ tv: UITextView) -> Int {
            offset(tv, at: CGPoint(x: tv.textContainerInset.left + 2, y: tv.contentOffset.y + tv.textContainerInset.top + 2))
        }

        func visibleRange(_ tv: UITextView) -> TextSpan {
            let start = topOffset(tv)
            let end = offset(tv, at: CGPoint(x: tv.bounds.width - tv.textContainerInset.right - 2, y: tv.contentOffset.y + tv.bounds.height - 2))
            return TextSpan(start: start, end: max(start, end))
        }

        func reportVisible(_ tv: UITextView) {
            guard tv.bounds.height > 0 else { return }
            parent.onVisibleRange(visibleRange(tv))
        }

        func scroll(_ tv: UITextView, toOffset offset: Int, animated: Bool) {
            guard let pos = tv.position(from: tv.beginningOfDocument, offset: max(0, offset)) else { return }
            let rect = tv.caretRect(for: pos)
            let maxY = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
            let y = min(maxY, max(0, rect.minY - tv.textContainerInset.top))
            tv.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        }

        /// 翻页：按可见高度滚动；到章节首尾时通知切换章节。
        func turnPage(_ tv: UITextView, forward: Bool) {
            let page = tv.bounds.height - 60
            let maxY = max(0, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
            var y = tv.contentOffset.y + (forward ? page : -page)
            if forward && tv.contentOffset.y >= maxY - 1 { parent.onPageBoundary(true); return }
            if !forward && tv.contentOffset.y <= 1 { parent.onPageBoundary(false); return }
            y = min(maxY, max(0, y))
            tv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            reportVisible(tv)
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            let r = tv.selectedRange
            let span: TextSpan? = r.length > 0 ? TextSpan(start: r.location, end: r.location + r.length) : nil
            if parent.selection != span { DispatchQueue.main.async { self.parent.selection = span } }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if let tv = scrollView as? UITextView { reportVisible(tv) }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate, let tv = scrollView as? UITextView { reportVisible(tv) }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let actions = [
                UIAction(title: "高亮") { [weak self] _ in self?.parent.onMenuAction(.highlight) },
                UIAction(title: "批注") { [weak self] _ in self?.parent.onMenuAction(.note) },
                UIAction(title: "提问") { [weak self] _ in self?.parent.onMenuAction(.ask) },
                UIAction(title: "记录反思") { [weak self] _ in self?.parent.onMenuAction(.reflect) },
            ]
            return UIMenu(children: actions + suggestedActions)
        }
    }
}
#else
/// macOS 类型检查用的简化正文视图（本项目不交付 macOS 应用）。
struct ReaderTextView: View {
    let chapter: Chapter
    let highlights: [Annotation]
    let preferences: ReaderPreferences
    @Binding var selection: TextSpan?
    let jump: ReaderModel.JumpRequest?
    let pageCommand: ReaderModel.PageCommand?
    let onVisibleRange: (TextSpan) -> Void
    let onMenuAction: (MenuAction) -> Void
    let onPageBoundary: (Bool) -> Void
    enum MenuAction { case highlight, note, ask, reflect }

    var body: some View {
        ScrollView { Text(chapter.text).font(.system(size: preferences.fontSize)).padding() }
            .onAppear { onVisibleRange(TextSpan(start: 0, end: chapter.length)) }
    }
}
#endif
