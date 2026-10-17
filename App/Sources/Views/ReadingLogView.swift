import SwiftUI
import LibraryCore
import ReadingSessionCore
import AchievementCore

/// 阅读记录：会话、连续阅读与成就；规则在页面上说明（HABIT-01）。
struct ReadingLogView: View {
    @Environment(AppModel.self) private var app
    @State private var stats: ReadingStats?
    @State private var sessions: [ReadingSession] = []
    @State private var achievements: [UnlockedAchievement] = []
    @State private var reflectionCount = 0

    var body: some View {
        NavigationStack {
            List {
                if let stats {
                    Section("概览") {
                        LabeledContent("累计阅读", value: String(format: "%.1f 小时", stats.totalSeconds / 3600))
                        LabeledContent("当前连续", value: "\(stats.currentStreak) 天").accessibilityIdentifier("log.streak")
                        LabeledContent("最长连续", value: "\(stats.longestStreak) 天")
                        LabeledContent("阅读会话", value: "\(stats.sessionCount) 次")
                        LabeledContent("已保存反思", value: "\(reflectionCount) 条")
                    }
                }
                Section {
                    if achievements.isEmpty { Text("继续阅读来解锁成就").foregroundStyle(.secondary) }
                    ForEach(achievements) { a in
                        VStack(alignment: .leading) {
                            Text(a.title).font(.headline)
                            Text(a.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("log.achievement")
                    }
                } header: { Text("成就") } footer: {
                    Text("规则：会话的前台时长按跨越的日历日分配；某日累计满 5 分钟记为阅读日；连续天数按你所在时区的日历日计算。屏幕停留只代表记录规则，不代表理解程度。")
                }
                Section("最近会话") {
                    ForEach(sessions.prefix(30)) { s in
                        HStack {
                            Text(app.books.first { $0.id == s.bookID }?.title ?? "已删除的书").lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f 分钟", s.activeSeconds / 60)).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .navigationTitle("阅读记录")
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        let c = app.container
        sessions = ((try? await c.readingRepository.sessions(bookID: nil)) ?? []).sorted { $0.startedAt > $1.startedAt }
        stats = HabitCalculator.stats(sessions: sessions, timeZone: app.timeZone, now: c.environment.clock.now())
        reflectionCount = ((try? await c.reflections.reflections(bookID: nil)) ?? []).count
        var annotationCount = 0
        var completed = 0
        for b in app.books {
            annotationCount += ((try? await c.readingRepository.annotations(bookID: b.id)) ?? []).count
            if b.displayProgress >= 0.999 { completed += 1 }
        }
        let attempts = ((try? await c.learningRepository.items(bookID: nil)) ?? []).count
        _ = try? await c.achievements.refresh(sessions: sessions, snapshot: HabitSnapshot(reflectionCount: reflectionCount, annotationCount: annotationCount,
                                                                                         attemptCount: attempts > 0 ? attempts : 0, completedBookCount: completed),
                                              timeZone: app.timeZone)
        achievements = ((try? await c.runtimeStore.unlocked()) ?? []).sorted { $0.unlockedAt > $1.unlockedAt }
    }
}
