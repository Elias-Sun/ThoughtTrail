import Foundation
import Network
import SpeechCore
#if os(iOS)
import AVFoundation
import Speech
#endif

/// 网络可用性监测（DATA-04 离线状态）。
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.thoughttrail.network")

    func start(_ handler: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in handler(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

/// 录音文件目录（沙盒）。
enum AudioStorage {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ fileName: String) -> URL { directory.appendingPathComponent(fileName) }
}

#if os(iOS)
/// 麦克风权限（AVAudioApplication）。
struct SystemMicrophonePermission: MicrophonePermission {
    func status() async -> PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func request() async -> PermissionState {
        await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }
}

/// 语音识别权限。
struct SystemSpeechPermission: SpeechPermission {
    func status() async -> PermissionState { Self.map(SFSpeechRecognizer.authorizationStatus()) }

    func request() async -> PermissionState {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: Self.map($0)) }
        }
    }

    static func map(_ s: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }
}

/// AVAudioRecorder 录音。音频会话被中断（来电）时由 VoiceCaptureController.handleInterruption 处理。
actor SystemAudioRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?

    func start(fileName: String) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio)
        try session.setActive(true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        let r = try AVAudioRecorder(url: AudioStorage.url(fileName), settings: settings)
        guard r.record() else { throw CocoaError(.fileWriteUnknown) }
        recorder = r
        startedAt = Date()
    }

    func stop() async throws -> TimeInterval {
        let duration = recorder?.currentTime ?? Date().timeIntervalSince(startedAt ?? Date())
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    func deleteFile(_ fileName: String) async {
        try? FileManager.default.removeItem(at: AudioStorage.url(fileName))
    }
}

/// SFSpeechRecognizer 文件转写（设备端可用时优先设备端）。
struct SystemTranscriber: SpeechTranscribing {
    func isAvailable(localeIdentifier: String) async -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))?.isAvailable ?? false
    }

    func transcribe(fileName: String, localeIdentifier: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else { throw CocoaError(.featureUnsupported) }
        let request = SFSpeechURLRecognitionRequest(url: AudioStorage.url(fileName))
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { c in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    let nsError = error as NSError
                    // 1110：没有检测到语音
                    if nsError.code == 1110 { c.resume(returning: "") } else { c.resume(throwing: error) }
                } else if let result, result.isFinal {
                    resumed = true
                    c.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}
#endif

/// UI 自动化/不支持录音的环境中的语音桩（确定性转写）。
struct StubVoice: MicrophonePermission, SpeechPermission, AudioRecording, SpeechTranscribing {
    var permission: PermissionState = .granted
    func status() async -> PermissionState { permission }
    func request() async -> PermissionState { permission }
    func start(fileName: String) async throws {}
    func stop() async throws -> TimeInterval { 2 }
    func deleteFile(_ fileName: String) async {}
    func isAvailable(localeIdentifier: String) async -> Bool { true }
    func transcribe(fileName: String, localeIdentifier: String) async throws -> String { "这是语音转写的反思内容" }
}

enum VoiceFactory {
    static func controller(deterministic: Bool, deniedForTesting: Bool = false) -> VoiceCaptureController {
        #if os(iOS)
        if !deterministic {
            return VoiceCaptureController(microphone: SystemMicrophonePermission(), speech: SystemSpeechPermission(),
                                          recorder: SystemAudioRecorder(), transcriber: SystemTranscriber())
        }
        #endif
        let stub = StubVoice(permission: deniedForTesting ? .denied : .granted)
        return VoiceCaptureController(microphone: stub, speech: stub, recorder: stub, transcriber: stub)
    }
}
