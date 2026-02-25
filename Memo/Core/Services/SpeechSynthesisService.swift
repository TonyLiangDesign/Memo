import AVFoundation

/// 语音合成服务 — 用 AVSpeechSynthesizer 朗读中文文本
/// 优先使用 premium/enhanced 高质量声音
@Observable @MainActor
final class SpeechSynthesisService: NSObject {
    var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (() -> Void)?
    private let voice: AVSpeechSynthesisVoice?

    override init() {
        self.voice = Self.bestChineseVoice()
        super.init()
        synthesizer.delegate = self
    }

    /// 朗读文本，完成后调用 onFinished（会打断当前朗读）
    func speak(_ text: String, onFinished: (() -> Void)? = nil) {
        synthesizer.stopSpeaking(at: .immediate)
        completion = onFinished

        ensurePlaybackSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// 追加一句到朗读队列（不打断当前朗读），用于流式实时 TTS
    func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        ensurePlaybackSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// 确保音频会话处于可播放状态（语音识别后可能还在 .record 模式）
    private func ensurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback && session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        completion = nil
    }

    // MARK: - Voice Selection

    /// 从系统可用声音中选最高质量的中文声音：premium > enhanced > default
    private static func bestChineseVoice() -> AVSpeechSynthesisVoice? {
        let zhVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh-CN") }

        // 按质量降序排列，取第一个
        let sorted = zhVoices.sorted { a, b in
            a.quality.rawValue > b.quality.rawValue
        }
        return sorted.first ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechSynthesisService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            let cb = self.completion
            self.completion = nil
            cb?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.completion = nil
        }
    }
}
