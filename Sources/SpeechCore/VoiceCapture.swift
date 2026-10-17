import Foundation
import LibraryCore

/// 系统权限状态（录音、语音识别）。
public enum PermissionState: String, Codable, Sendable {
    case notDetermined, granted, denied, restricted
}

/// 语音输入失败原因。所有失败都允许用户继续文字输入（REF-03）。
public enum VoiceFailure: Error, Equatable, Sendable {
    case microphoneDenied
    case speechRecognitionDenied
    case recognizerUnavailable
    case interrupted
    case noSpeechDetected
    case recordingFailed(String)
    case transcriptionFailed(String)

    public var userMessage: String {
        switch self {
        case .microphoneDenied: return "未获得麦克风权限。可在系统设置中开启，或直接用文字记录。"
        case .speechRecognitionDenied: return "未获得语音识别权限。录音已保留，可手动输入文字。"
        case .recognizerUnavailable: return "当前语言或网络下语音转写不可用，可改用文字输入。"
        case .interrupted: return "录音被中断（例如来电），已保留中断前的录音。"
        case .noSpeechDetected: return "没有识别到语音内容，请重试或改用文字输入。"
        case .recordingFailed(let r): return "录音失败：\(r)"
        case .transcriptionFailed(let r): return "转写失败：\(r)"
        }
    }
}

/// 平台适配接口（App 层用 AVAudioRecorder / SFSpeechRecognizer 实现）。
public protocol MicrophonePermission: Sendable {
    func status() async -> PermissionState
    func request() async -> PermissionState
}

public protocol SpeechPermission: Sendable {
    func status() async -> PermissionState
    func request() async -> PermissionState
}

public protocol AudioRecording: Sendable {
    /// 开始录音到指定文件名（沙盒内）。
    func start(fileName: String) async throws
    /// 停止录音，返回时长（秒）。
    func stop() async throws -> TimeInterval
    func deleteFile(_ fileName: String) async
}

public protocol SpeechTranscribing: Sendable {
    func isAvailable(localeIdentifier: String) async -> Bool
    /// 转写录音。返回空字符串表示没有识别到语音。
    func transcribe(fileName: String, localeIdentifier: String) async throws -> String
}

/// 语音录入状态机。
public enum VoiceCaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording(fileName: String, startedAt: Date)
    case transcribing(fileName: String, duration: TimeInterval)
    /// 转写完成，用户可编辑后提交。
    case editing(fileName: String?, transcript: String, edited: String)
    /// 失败但保留录音与已有文字，用户可文字输入继续。
    case failed(VoiceFailure, fileName: String?, fallbackText: String)
    case submitted(text: String)

    public var isBusy: Bool {
        switch self {
        case .requestingPermission, .recording, .transcribing: return true
        default: return false
        }
    }
}

/// 语音录入控制器：录音 → 停止 → 转写 → 人工修改 → 提交。
public actor VoiceCaptureController {
    public private(set) var state: VoiceCaptureState = .idle
    private let microphone: MicrophonePermission
    private let speech: SpeechPermission
    private let recorder: AudioRecording
    private let transcriber: SpeechTranscribing
    private let clock: WallClock
    private let ids: IDGenerating
    public let localeIdentifier: String
    public static let maxDuration: TimeInterval = 600

    public init(microphone: MicrophonePermission, speech: SpeechPermission, recorder: AudioRecording,
                transcriber: SpeechTranscribing, localeIdentifier: String = "zh-CN",
                clock: WallClock = SystemClock(), ids: IDGenerating = UUIDGenerator()) {
        self.microphone = microphone; self.speech = speech; self.recorder = recorder
        self.transcriber = transcriber; self.localeIdentifier = localeIdentifier
        self.clock = clock; self.ids = ids
    }

    @discardableResult
    public func startRecording(existingText: String = "") async -> VoiceCaptureState {
        guard !state.isBusy else { return state }
        state = .requestingPermission
        var mic = await microphone.status()
        if mic == .notDetermined { mic = await microphone.request() }
        guard mic == .granted else {
            state = .failed(.microphoneDenied, fileName: nil, fallbackText: existingText)
            return state
        }
        let fileName = ids.make("voice") + ".m4a"
        do {
            try await recorder.start(fileName: fileName)
            state = .recording(fileName: fileName, startedAt: clock.now())
        } catch {
            state = .failed(.recordingFailed("\(error)"), fileName: nil, fallbackText: existingText)
        }
        return state
    }

    /// 停止录音并转写。
    @discardableResult
    public func stopAndTranscribe() async -> VoiceCaptureState {
        guard case .recording(let fileName, _) = state else { return state }
        let duration: TimeInterval
        do { duration = try await recorder.stop() } catch {
            state = .failed(.recordingFailed("\(error)"), fileName: fileName, fallbackText: "")
            return state
        }
        return await transcribe(fileName: fileName, duration: duration)
    }

    private func transcribe(fileName: String, duration: TimeInterval) async -> VoiceCaptureState {
        state = .transcribing(fileName: fileName, duration: duration)
        var perm = await speech.status()
        if perm == .notDetermined { perm = await speech.request() }
        guard perm == .granted else {
            state = .failed(.speechRecognitionDenied, fileName: fileName, fallbackText: "")
            return state
        }
        guard await transcriber.isAvailable(localeIdentifier: localeIdentifier) else {
            state = .failed(.recognizerUnavailable, fileName: fileName, fallbackText: "")
            return state
        }
        do {
            let text = try await transcriber.transcribe(fileName: fileName, localeIdentifier: localeIdentifier)
            // 转写期间被取消：保持取消后的状态
            guard case .transcribing = state else { return state }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                state = .failed(.noSpeechDetected, fileName: fileName, fallbackText: "")
            } else {
                state = .editing(fileName: fileName, transcript: trimmed, edited: trimmed)
            }
        } catch {
            guard case .transcribing = state else { return state }
            state = .failed(.transcriptionFailed("\(error)"), fileName: fileName, fallbackText: "")
        }
        return state
    }

    /// 系统中断（来电、切到后台）：停止录音，保留已录内容，允许用户继续文字输入。
    @discardableResult
    public func handleInterruption() async -> VoiceCaptureState {
        switch state {
        case .recording(let fileName, _):
            _ = try? await recorder.stop()
            state = .failed(.interrupted, fileName: fileName, fallbackText: "")
        case .transcribing(let fileName, _):
            state = .failed(.interrupted, fileName: fileName, fallbackText: "")
        default:
            break
        }
        return state
    }

    /// 中断后重新转写已保留的录音。
    @discardableResult
    public func retryTranscription() async -> VoiceCaptureState {
        guard case .failed(let failure, let fileName?, _) = state,
              failure != .microphoneDenied else { return state }
        return await transcribe(fileName: fileName, duration: 0)
    }

    /// 人工修改转写文字。
    public func edit(_ text: String) {
        switch state {
        case .editing(let f, let t, _): state = .editing(fileName: f, transcript: t, edited: text)
        case .failed(let failure, let f, _): state = .failed(failure, fileName: f, fallbackText: text)
        case .idle: state = .editing(fileName: nil, transcript: "", edited: text)
        default: break
        }
    }

    /// 提交最终文字（转写修改后或失败后的文字输入）。返回 nil 表示没有可提交内容。
    public func submit() -> String? {
        let text: String
        switch state {
        case .editing(_, _, let edited): text = edited
        case .failed(_, _, let fallback): text = fallback
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        state = .submitted(text: trimmed)
        return trimmed
    }

    /// 取消：停止录音并删除音频文件。
    public func cancel() async {
        switch state {
        case .recording(let fileName, _):
            _ = try? await recorder.stop()
            await recorder.deleteFile(fileName)
        case .transcribing(let fileName, _), .editing(let fileName?, _, _), .failed(_, let fileName?, _):
            await recorder.deleteFile(fileName)
        default: break
        }
        state = .idle
    }

    /// 录音中转写使用的原始转写稿（保存到反思的 originalTranscript）。
    public var originalTranscript: String? {
        if case .editing(_, let t, _) = state, !t.isEmpty { return t }
        return nil
    }

    public var audioFileName: String? {
        switch state {
        case .recording(let f, _), .transcribing(let f, _): return f
        case .editing(let f, _, _), .failed(_, let f, _): return f
        default: return nil
        }
    }

    public func reset() { state = .idle }

    /// 定时检查：录音超过上限自动停止并转写，防止无界录音。
    @discardableResult
    public func enforceDurationLimit() async -> VoiceCaptureState {
        guard case .recording(_, let startedAt) = state,
              clock.now().timeIntervalSince(startedAt) >= Self.maxDuration else { return state }
        return await stopAndTranscribe()
    }
}
