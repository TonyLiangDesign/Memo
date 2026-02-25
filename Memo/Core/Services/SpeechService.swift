import Foundation
import Speech
import AVFoundation

/// 语音识别服务，封装 SFSpeechRecognizer + AVAudioEngine，中文离线识别
@Observable @MainActor
final class SpeechService {
    var isListening = false
    var recognizedText = ""
    var error: String?
    var permissionGranted = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func checkPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                switch status {
                case .authorized:
                    self?.permissionGranted = true
                    self?.error = nil
                default:
                    self?.permissionGranted = false
                    self?.error = String(localized: "请在设置中允许语音识别权限")
                }
            }
        }
    }

    func startListening(configureAudioSession: Bool = true) {
        guard permissionGranted else {
            error = String(localized: "请在设置中允许语音识别权限")
            return
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = String(localized: "语音识别不可用")
            return
        }

        stopListening()
        recognizedText = ""
        error = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        let audioSession = AVAudioSession.sharedInstance()
        if configureAudioSession {
            do {
                try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                self.error = String(localized: "无法启动麦克风")
                return
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // ARKit may hold the audio session, leaving the input node with an invalid format
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            self.error = String(localized: "麦克风暂不可用，请稍后重试")
            recognitionRequest = nil
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        do {
            try audioEngine.start()
            isListening = true
        } catch {
            self.error = String(localized: "无法启动录音")
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.recognizedText = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self?.stopListening()
                }
            }
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }
}