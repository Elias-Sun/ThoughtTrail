import Foundation
import SpeechCore
import AgentRuntime

/// 需要的系统能力与网络条件。
public enum OperationKind: String, Sendable, CaseIterable {
    case readBook, annotate, reflectText, browseMemories, exportBackup
    case discuss, embedIndex, rerank, proposeMemories, generateQuiz, gradeAnswer
    case voiceTranscription

    /// 只依赖本地数据的操作离线可用（DATA-04）。
    public var requiresNetwork: Bool {
        switch self {
        case .readBook, .annotate, .reflectText, .browseMemories, .exportBackup: return false
        case .voiceTranscription: return false // 设备端识别可用时无需网络，否则由识别器报告不可用
        default: return true
        }
    }

    public var requiresChatModel: Bool {
        [.discuss, .proposeMemories, .generateQuiz, .gradeAnswer].contains(self)
    }
}

public enum Availability: Equatable, Sendable {
    case available
    /// 离线：操作会保留输入，联网后可重试。
    case pendingNetwork(String)
    case notConfigured(String)

    public var isAvailable: Bool { self == .available }
}

/// 离线与配置可用性策略：需要在线模型的操作显示待处理或不可用，不假装已完成。
public enum OfflinePolicy {
    public static func availability(of op: OperationKind, online: Bool, chatConfigured: Bool, embeddingConfigured: Bool) -> Availability {
        if op.requiresChatModel && !chatConfigured { return .notConfigured("请先在设置中配置对话模型") }
        if op == .embedIndex && !embeddingConfigured { return .notConfigured("未配置向量模型，将仅使用词法检索") }
        if op.requiresNetwork && !online { return .pendingNetwork("当前离线，输入已保留，联网后可重试") }
        return .available
    }
}

/// 系统权限状态 → 用户指引（M14 权限映射）。
public struct PermissionGuidance: Equatable, Sendable {
    public var message: String
    public var canRequest: Bool
    public var opensSettings: Bool
    public var allowsTextFallback: Bool
}

public enum PermissionMapper {
    public static func microphone(_ state: PermissionState) -> PermissionGuidance {
        switch state {
        case .granted:
            return PermissionGuidance(message: "可以录音", canRequest: false, opensSettings: false, allowsTextFallback: true)
        case .notDetermined:
            return PermissionGuidance(message: "录音需要麦克风权限", canRequest: true, opensSettings: false, allowsTextFallback: true)
        case .denied:
            return PermissionGuidance(message: "麦克风权限已关闭，可在系统设置中开启；现在也可以直接输入文字。",
                                      canRequest: false, opensSettings: true, allowsTextFallback: true)
        case .restricted:
            return PermissionGuidance(message: "此设备限制了麦克风使用，请改用文字输入。", canRequest: false, opensSettings: false, allowsTextFallback: true)
        }
    }

    public static func speech(_ state: PermissionState) -> PermissionGuidance {
        switch state {
        case .granted:
            return PermissionGuidance(message: "可以转写", canRequest: false, opensSettings: false, allowsTextFallback: true)
        case .notDetermined:
            return PermissionGuidance(message: "转写需要语音识别权限", canRequest: true, opensSettings: false, allowsTextFallback: true)
        case .denied:
            return PermissionGuidance(message: "语音识别权限已关闭，录音会保留，可手动输入文字。",
                                      canRequest: false, opensSettings: true, allowsTextFallback: true)
        case .restricted:
            return PermissionGuidance(message: "此设备不支持语音识别，请改用文字输入。", canRequest: false, opensSettings: false, allowsTextFallback: true)
        }
    }
}

/// 数据处理说明（7.3），首次配置与设置页展示。
public enum DataProcessingNotice {
    public static let text = """
    · EPUB、批注、反思、记忆和数据库保存在本设备。
    · 使用云端向量模型时，待索引的已读文本会发送到你配置的模型服务；默认只对已读范围增量处理。
    · 讨论、重排、证据复核和出题会发送该任务所需的文本与上下文。
    · 本地会解析全书结构并建立词法索引，但召回与组装始终受阅读范围限制。
    · 密钥只保存在系统钥匙串，不写入日志、截图或导出包。
    """
}

/// 应用生命周期事件映射（前后台 → 会话暂停/恢复）。
public enum LifecycleEvent: String, Sendable {
    case didEnterBackground, willEnterForeground, willTerminate
}
