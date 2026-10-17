import SwiftUI
import LibraryCore
import ReflectionCore
import SpeechCore
import AppInfrastructure

/// 反思编辑器：文字或语音输入，草稿自动保存，提交幂等；冻结当时的阅读现场（REF-01/02/03）。
struct ReflectionSheet: View {
    let reader: ReaderModel?
    var existingDraft: Reflection? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Reflection?
    @State private var text = ""
    @State private var voice: VoiceCaptureController?
    @State private var voiceState: VoiceCaptureState = .idle
    @State private var commitKey = UUID().uuidString
    @State private var saving = false
    @State private var startDiscussion = false

    var body: some View {
        NavigationStack {
            Form {
                if let ctx = draft?.context {
                    Section("阅读现场") {
                        Text("《\(ctx.bookTitle)》\(ctx.chapterTitle.map { " · \($0)" } ?? "")").font(.caption)
                        if let sel = ctx.selectedText { Text(sel).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("reflection.selection") }
                    }
                }
                Section("我的想法") {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .accessibilityIdentifier("reflection.text")
                        .onChange(of: text) { _, newValue in autosave(newValue) }
                }
                Section("语音") {
                    voiceControls
                }
            }
            .navigationTitle("记录反思")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("稍后继续") { dismiss() }.accessibilityIdentifier("reflection.later") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await commit() } }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("reflection.save")
                }
            }
        }
        .task { await prepare() }
    }

    @ViewBuilder
    private var voiceControls: some View {
        switch voiceState {
        case .idle, .submitted:
            Button("开始录音", systemImage: "mic") { Task { await startRecording() } }.accessibilityIdentifier("voice.start")
        case .requestingPermission:
            ProgressView("请求权限…")
        case .recording:
            HStack {
                Label("录音中", systemImage: "waveform").foregroundStyle(.red)
                Spacer()
                Button("停止并转写") { Task { await stop() } }.accessibilityIdentifier("voice.stop")
                Button("取消", role: .destructive) { Task { await voice?.cancel(); voiceState = .idle } }
                    .accessibilityIdentifier("voice.cancel")
            }
            // 同一行内多个按钮必须用 borderless，否则点击整行会同时触发“停止”和“取消”
            .buttonStyle(.borderless)
        case .transcribing:
            ProgressView("转写中…")
        case .editing(_, let transcript, _):
            VStack(alignment: .leading) {
                Text("转写结果已加入正文，可直接修改。").font(.caption)
                Text("原始转写：\(transcript)").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("voice.transcript")
            }
        case .failed(let failure, _, _):
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.userMessage).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("voice.error")
                if failure != .microphoneDenied {
                    Button("重新转写") { Task { await retry() } }
                }
            }
        }
    }

    private func prepare() async {
        voice = VoiceFactory.controller(deterministic: app.launch.deterministic,
                                        deniedForTesting: ProcessInfo.processInfo.arguments.contains("-uitest-deny-mic"))
        if let existingDraft {
            draft = existingDraft
            text = existingDraft.text
        } else if let reader {
            let context = await reader.contextSnapshot()
            draft = try? await app.container.reflections.startDraft(context: context)
        }
    }

    private func autosave(_ value: String) {
        guard let id = draft?.id, draft?.state == .draft else { return }
        let service = app.container.reflections
        Task { _ = try? await service.updateDraft(id: id, text: value) }
    }

    private func startRecording() async {
        guard let voice else { return }
        voiceState = await voice.startRecording(existingText: text)
    }

    private func stop() async {
        guard let voice else { return }
        voiceState = await voice.stopAndTranscribe()
        await applyTranscript()
    }

    private func retry() async {
        guard let voice else { return }
        voiceState = await voice.retryTranscription()
        await applyTranscript()
    }

    private func applyTranscript() async {
        guard case .editing(let file, let transcript, _) = voiceState, let id = draft?.id else { return }
        text = text.isEmpty ? transcript : text + "\n" + transcript
        draft = try? await app.container.reflections.updateDraft(id: id, text: text, transcript: transcript, audioFileName: file)
    }

    private func commit() async {
        guard let id = draft?.id else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await app.container.reflections.updateDraft(id: id, text: text)
            _ = try await app.container.reflections.commit(id: id, commitKey: commitKey)
            app.banner = .init(message: "反思已保存", isError: false)
            dismiss()
        } catch ReflectionError.alreadySaved {
            dismiss()
        } catch {
            app.banner = .init(message: "保存失败：\(error.localizedDescription)，内容已保留为草稿", isError: true)
        }
    }
}
