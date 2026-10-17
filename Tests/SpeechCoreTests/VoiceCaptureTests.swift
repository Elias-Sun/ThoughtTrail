import Testing
import Foundation
@testable import SpeechCore
import LibraryCore

actor FakePermission: MicrophonePermission, SpeechPermission {
    var current: PermissionState
    let afterRequest: PermissionState
    var requests = 0
    init(_ s: PermissionState, afterRequest: PermissionState = .granted) { current = s; self.afterRequest = afterRequest }
    func status() async -> PermissionState { current }
    func request() async -> PermissionState { requests += 1; current = afterRequest; return current }
}

actor FakeRecorder: AudioRecording {
    var started: [String] = []
    var stopped = 0
    var deleted: [String] = []
    var failStart = false
    func setFailStart() { failStart = true }
    func start(fileName: String) async throws {
        if failStart { throw CocoaError(.fileWriteNoPermission) }
        started.append(fileName)
    }
    func stop() async throws -> TimeInterval { stopped += 1; return 12 }
    func deleteFile(_ fileName: String) async { deleted.append(fileName) }
}

actor FakeTranscriber: SpeechTranscribing {
    var available = true
    var result: Result<String, Error> = .success("这是转写结果")
    var calls = 0
    func set(_ r: Result<String, Error>) { result = r }
    func setAvailable(_ v: Bool) { available = v }
    func isAvailable(localeIdentifier: String) async -> Bool { available }
    func transcribe(fileName: String, localeIdentifier: String) async throws -> String { calls += 1; return try result.get() }
}

@Suite("M05 语音录入")
struct VoiceCaptureTests {
    struct Rig {
        let mic: FakePermission
        let speech: FakePermission
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber()
        let clock = ManualClock()
        var controller: VoiceCaptureController {
            VoiceCaptureController(microphone: mic, speech: speech, recorder: recorder, transcriber: transcriber,
                                   clock: clock, ids: SequentialIDGenerator())
        }
    }

    func rig(mic: PermissionState = .granted, speech: PermissionState = .granted) -> (Rig, VoiceCaptureController) {
        let r = Rig(mic: FakePermission(mic), speech: FakePermission(speech))
        return (r, r.controller)
    }

    @Test("REF-03 录音→停止→转写→人工修改→提交 完整流程")
    func fullFlow() async {
        let (r, c) = rig()
        let s = await c.startRecording()
        guard case .recording(let file, _) = s else { Issue.record("应在录音"); return }
        #expect(await r.recorder.started == [file])
        let t = await c.stopAndTranscribe()
        #expect(t == .editing(fileName: file, transcript: "这是转写结果", edited: "这是转写结果"))
        await c.edit("这是修改后的结果")
        #expect(await c.originalTranscript == "这是转写结果")
        #expect(await c.submit() == "这是修改后的结果")
    }

    @Test("REF-03 首次使用请求麦克风权限，同意后开始录音")
    func requestsPermission() async {
        let r = Rig(mic: FakePermission(.notDetermined, afterRequest: .granted), speech: FakePermission(.granted))
        let c = r.controller
        let s = await c.startRecording()
        if case .recording = s {} else { Issue.record("应开始录音") }
        #expect(await r.mic.requests == 1)
    }

    @Test("REF-03 麦克风权限被拒绝时可继续文字输入")
    func micDeniedFallsBackToText() async {
        let (r, c) = rig(mic: .denied)
        let s = await c.startRecording(existingText: "已有文字")
        #expect(s == .failed(.microphoneDenied, fileName: nil, fallbackText: "已有文字"))
        #expect(await r.recorder.started.isEmpty)
        await c.edit("改用文字记录")
        #expect(await c.submit() == "改用文字记录")
    }

    @Test("REF-03 语音识别权限被拒绝时保留录音，可文字输入")
    func speechDeniedKeepsAudio() async {
        let (_, c) = rig(speech: .denied)
        _ = await c.startRecording()
        let s = await c.stopAndTranscribe()
        guard case .failed(.speechRecognitionDenied, let file?, _) = s else { Issue.record("应因识别权限失败"); return }
        #expect(await c.audioFileName == file)
    }

    @Test("REF-03 转写不可用（语言/网络）时给出明确状态")
    func recognizerUnavailable() async {
        let (r, c) = rig()
        await r.transcriber.setAvailable(false)
        _ = await c.startRecording()
        let s = await c.stopAndTranscribe()
        if case .failed(.recognizerUnavailable, _, _) = s {} else { Issue.record("应为不可用") }
        #expect(await r.transcriber.calls == 0)
    }

    @Test("REF-03 没有识别到语音时提示重试或文字输入")
    func noSpeech() async {
        let (r, c) = rig()
        await r.transcriber.set(.success("   "))
        _ = await c.startRecording()
        if case .failed(.noSpeechDetected, _, _) = await c.stopAndTranscribe() {} else { Issue.record("应为无语音") }
    }

    @Test("REF-03 转写失败给出错误并允许重新转写")
    func transcriptionFailureRetry() async {
        let (r, c) = rig()
        await r.transcriber.set(.failure(CocoaError(.featureUnsupported)))
        _ = await c.startRecording()
        if case .failed(.transcriptionFailed, _, _) = await c.stopAndTranscribe() {} else { Issue.record("应转写失败") }
        await r.transcriber.set(.success("重试成功"))
        if case .editing(_, let t, _) = await c.retryTranscription() { #expect(t == "重试成功") } else { Issue.record("应重试成功") }
    }

    @Test("REF-03 来电中断录音：保留已录内容并允许继续")
    func interruptionDuringRecording() async {
        let (r, c) = rig()
        _ = await c.startRecording()
        let s = await c.handleInterruption()
        guard case .failed(.interrupted, let file?, _) = s else { Issue.record("应为中断"); return }
        #expect(await r.recorder.stopped == 1)
        #expect(await r.recorder.deleted.isEmpty)
        if case .editing = await c.retryTranscription() {} else { Issue.record("中断后应可转写已录内容") }
        _ = file
    }

    @Test("REF-03 取消录音删除音频文件并回到空闲")
    func cancelDeletesAudio() async {
        let (r, c) = rig()
        guard case .recording(let file, _) = await c.startRecording() else { Issue.record("应录音"); return }
        await c.cancel()
        #expect(await r.recorder.deleted == [file])
        #expect(await c.state == .idle)
    }

    @Test("REF-03 录音启动失败不卡在忙碌状态")
    func recorderStartFailure() async {
        let (r, c) = rig()
        await r.recorder.setFailStart()
        let s = await c.startRecording()
        if case .failed(.recordingFailed, nil, _) = s {} else { Issue.record("应录音失败") }
        #expect(await c.state.isBusy == false)
    }

    @Test("REF-03 忙碌时重复点击录音不会启动第二段录音")
    func duplicateStartIgnored() async {
        let (r, c) = rig()
        _ = await c.startRecording()
        _ = await c.startRecording()
        #expect(await r.recorder.started.count == 1)
    }

    @Test("REF-03 超过最长录音时长自动停止并转写")
    func durationLimit() async {
        let (r, c) = rig()
        _ = await c.startRecording()
        r.clock.advance(by: 30)
        if case .recording = await c.enforceDurationLimit() {} else { Issue.record("未超时应继续录音") }
        r.clock.advance(by: VoiceCaptureController.maxDuration)
        if case .editing = await c.enforceDurationLimit() {} else { Issue.record("超时应自动转写") }
    }

    @Test("REF-03 没有内容时提交返回 nil")
    func submitEmpty() async {
        let (_, c) = rig(mic: .denied)
        _ = await c.startRecording()
        #expect(await c.submit() == nil)
        #expect(await c.submit() == nil)
    }

    @Test("REF-03 停止前未录音的停止调用不改变状态")
    func stopWithoutRecording() async {
        let (r, c) = rig()
        #expect(await c.stopAndTranscribe() == .idle)
        #expect(await r.recorder.stopped == 0)
    }

    @Test("REF-03 转写中被取消，迟到的转写结果不覆盖取消状态")
    func lateTranscriptionIgnoredAfterCancel() async {
        let (r, c) = rig()
        _ = await c.startRecording()
        await r.transcriber.set(.success("迟到的结果"))
        async let result = c.stopAndTranscribe()
        await c.cancel()
        _ = await result
        // 无论取消与转写谁先完成，最终都停在取消后的空闲状态
        #expect(await c.state == .idle)
    }

    @Test("REF-03 失败状态下编辑文字作为降级输入")
    func editInFailedState() async {
        let (_, c) = rig(speech: .denied)
        _ = await c.startRecording()
        _ = await c.stopAndTranscribe()
        await c.edit("手动输入")
        #expect(await c.submit() == "手动输入")
    }
}
