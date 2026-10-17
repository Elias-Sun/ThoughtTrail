import SwiftUI
import LibraryCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.library

    enum Tab: Hashable { case library, brain, learning, log, settings }

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label("书库", systemImage: "books.vertical") }
                .tag(Tab.library)
            BrainView()
                .tabItem { Label("思考与记忆", systemImage: "brain") }
                .tag(Tab.brain)
            LearningView()
                .tabItem { Label("自测与复习", systemImage: "checklist") }
                .tag(Tab.learning)
            ReadingLogView()
                .tabItem { Label("阅读记录", systemImage: "chart.bar") }
                .tag(Tab.log)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .top) { BannerView() }
        .onChange(of: model.openRequest) { _, request in
            if request != nil { tab = .library }
        }
    }
}

/// 全局提示条（导入结果、错误等）。
struct BannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let banner = model.banner {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? .orange : .green)
                Text(banner.message)
                    .font(.callout)
                    .accessibilityIdentifier("banner.message")
                Spacer(minLength: 4)
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .accessibilityLabel("关闭提示")
                .accessibilityIdentifier("banner.close")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            // 放在导航栏下方，避免遮挡导航栏按钮（目录、更多等）
            .padding(.top, 60)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: banner.id) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if model.banner?.id == banner.id { model.banner = nil }
            }
        }
    }
}

/// 状态徽标（讨论消息、提议等）。
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// 空状态。
struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}
