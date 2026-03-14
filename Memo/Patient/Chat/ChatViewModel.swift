import Foundation
import os.log
import EverMemOSKit

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "ChatVM")

// MARK: - Tool Calling Types

private struct ToolCall {
    let id: String
    let functionName: String
    let arguments: [String: Any]
}

private enum Phase1Result {
    case textResponse(String)
    case toolCalls(assistantMessage: [String: Any], calls: [ToolCall])
}

/// A single chat bubble for display
struct ChatMessage: Identifiable {
    let id: String
    let role: ChatRole
    var text: String
    let timestamp: Date

    enum ChatRole { case user, assistant }
}

/// Manages chat session state: fetches memory from EverMemOS, streams responses from DeepSeek directly.
@Observable @MainActor
final class ChatViewModel {
    // MARK: - Published state

    var messages: [ChatMessage] = []
    var streamingText: String = ""
    var isStreaming: Bool = false
    var errorMessage: String?
    var showRetry: Bool = false

    /// Called when streaming finishes (for LiveMode to know when AI reply is done)
    var onStreamingFinished: (() -> Void)?

    // MARK: - Session

    let sessionID: String
    private let userID: String
    private let groupID: String

    // MARK: - Dependencies

    private let apiClient: EverMemOSClient?
    private let deepSeekAPIKey: String?
    private var tts: SpeechSynthesisService?
    private var ttsSentenceBuffer: String = ""
    var perceptionState: PerceptionStateStore?
    var faceRecognitionService: FaceRecognitionService?

    init(
        apiClient: EverMemOSClient?,
        userID: String = "patient",
        groupID: String = "memo_patient_default_group",
        deepSeekAPIKey: String? = nil,
        tts: SpeechSynthesisService? = nil,
        perceptionState: PerceptionStateStore? = nil,
        faceRecognitionService: FaceRecognitionService? = nil
    ) {
        self.sessionID = UUID().uuidString
        self.userID = userID
        self.groupID = groupID
        self.apiClient = apiClient
        self.deepSeekAPIKey = deepSeekAPIKey
        self.tts = tts
        self.perceptionState = perceptionState
        self.faceRecognitionService = faceRecognitionService
    }

    // MARK: - Send message

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        let messageID = UUID().uuidString

        // Add user bubble
        messages.append(ChatMessage(id: messageID, role: .user, text: trimmed, timestamp: Date()))

        // Reset state
        streamingText = ""
        isStreaming = true
        errorMessage = nil
        showRetry = false

        // Prepare assistant placeholder
        let assistantID = UUID().uuidString
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: "", timestamp: Date()))

        Task {
            await streamDeepSeek(text: trimmed, assistantID: assistantID)
        }
    }

    /// Retry last failed message
    func retry() {
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return }
        if let lastAssistant = messages.last, lastAssistant.role == .assistant {
            messages.removeLast()
        }
        sendMessage(lastUser.text)
    }

    /// Append a local user message without triggering DeepSeek.
    func appendLocalUserMessage(_ text: String, memorize: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(
            id: UUID().uuidString,
            role: .user,
            text: trimmed,
            timestamp: Date()
        ))
        if memorize {
            memorizeUserContent(trimmed)
        }
    }

    /// Append a local assistant reply, optionally with TTS.
    func appendLocalAssistantMessage(_ text: String, speak: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            text: trimmed,
            timestamp: Date()
        ))
        if speak {
            tts?.stop()
            feedTTSFull(trimmed)
        }
    }

    /// Record non-chat behavior (e.g. dial attempts, face recognition) into EverMemOS.
    func recordPatientBehavior(_ content: String, flush: Bool = false) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        memorizeUserContent(trimmed, flush: flush)
    }

    // MARK: - Tool Definitions

    private static var memoryTools: [[String: Any]] {
        let isEnglish = Locale.current.language.languageCode?.identifier == "en"

        let searchMemoryDesc = isEnglish ? """
            Search patient's memory records. Call when user asks about:
            - Item locations (keys, glasses, phone, etc.)
            - Medication (what medicine taken, when)
            - People info (who someone is, phone numbers)
            - Past events (what happened yesterday, last hospital visit)
            - Schedule (what's today, when is checkup)
            Don't call for: greetings, small talk, common knowledge, emotions, thanks.
            """ : """
            搜索患者的记忆记录。当用户询问以下内容时调用：
            - 物品放在哪里（钥匙、眼镜、手机等）
            - 药物相关（吃了什么药、什么时候吃）
            - 人物信息（某人是谁、电话号码）
            - 过去发生的事（昨天做了什么、上次去医院）
            - 日程安排（今天有什么事、什么时候复查）
            不要在以下情况调用：问候、闲聊、常识问题、情绪表达、感谢。
            """

        let queryDesc = isEnglish ? "Refined search keywords, e.g. where are keys, blood pressure medication record" : "提炼后的搜索关键词，如钥匙放在哪、降压药服用记录"
        let topKDesc = isEnglish ? "Number of results, default 5" : "返回结果数量，默认5"
        let whoIsDesc = isEnglish ? "Check who is currently visible to the patient. Call when patient asks 'who is this', 'who is in front of me', 'who is he/she'." : "查看当前患者视线中的人物。当患者问'这是谁'、'面前是谁'、'他/她是谁'时调用。"

        return [
            [
                "type": "function",
                "function": [
                    "name": "search_memory",
                    "description": searchMemoryDesc,
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": queryDesc
                            ],
                            "top_k": [
                                "type": "integer",
                                "description": topKDesc
                            ]
                        ],
                        "required": ["query"]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "type": "function",
                "function": [
                    "name": "who_is_visible",
                    "description": whoIsDesc,
                    "parameters": [
                        "type": "object",
                        "properties": [:] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        ]
    }

    // MARK: - Agentic System Prompt

    private func buildAgenticSystemPrompt() -> String {
        let isEnglish = Locale.current.language.languageCode?.identifier == "en"
        let df = DateFormatter()
        df.locale = isEnglish ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        df.dateFormat = isEnglish ? "MMM d, yyyy HH:mm" : "yyyy年M月d日 HH:mm"
        let currentTime = df.string(from: Date())

        var prompt = ""

        if isEnglish {
            prompt = """
            You are a warm, patient memory assistant helping Alzheimer's patients recall daily life.

            ## Tools
            You have a `search_memory` tool to search patient's memory records.
            - Call it when user asks about item locations, medications, people, past events, schedules.
            - Don't call for greetings, small talk, common knowledge, or emotions.

            You also have a `who_is_visible` tool to check who is in patient's view.
            - Call it when user asks "who is this", "who is in front of me", "who is he/she".

            ## Response Rules
            1. Keep responses to 2-3 sentences, short and clear
            2. Include record time when answering (e.g. "recorded at 10am today")
            3. Be patient with repeated questions
            4. Gently remind about missed medications
            5. Don't provide medical advice
            6. Say "I don't have that record" when no relevant memory
            7. Say "memory system temporarily unavailable" on tool errors

            ## Current Time
            \(currentTime)
            """
        } else {
            prompt = """
            你是一位温暖、耐心的记忆助手，帮助阿尔茨海默症患者回忆日常生活。

            ## 工具
            你有一个 `search_memory` 工具可以搜索患者的记忆记录。
            - 当用户问到物品位置、药物、人物、过去的事、日程时，调用它。
            - 当用户只是打招呼、闲聊、问常识、表达情绪时，直接回答，不要调用。

            你还有一个 `who_is_visible` 工具可以查看患者视线中的人物。
            - 当用户问"这是谁"、"面前是谁"、"他/她是谁"时，调用它。

            ## 回答规则
            1. 每次 2-3 句话，简短清晰
            2. 能回答时带上记录时间（如"今天上午10点记录的"）
            3. 耐心对待重复提问
            4. 发现未服药物时温和提醒
            5. 不提供医疗建议
            6. 没有相关记忆时明确说"我这里没有这个记录"
            7. 工具返回错误时，告诉用户"记忆系统暂时不可用"

            ## 当前时间
            \(currentTime)
            """
        }

        if let context = perceptionState?.contextSummary {
            if isEnglish {
                prompt += """

                ## People Currently Visible
                \(context)
                If patient asks "who is this", prioritize calling who_is_visible tool for real-time info.
                """
            } else {
                prompt += """

                ## 当前视线中的人物
                \(context)
                如果患者问"这是谁"，优先调用 who_is_visible 工具获取实时信息。
                """
            }
        }

        return prompt
    }

    // MARK: - Direct DeepSeek streaming

    private func streamDeepSeek(text: String, assistantID: String) async {
        guard let apiKey = deepSeekAPIKey, !apiKey.isEmpty else {
            updateAssistant(id: assistantID, text: "（请先在设置中配置 DeepSeek API Key）")
            isStreaming = false
            return
        }

        // ① Build agentic conversation messages (no memory embedded)
        let systemPrompt = buildAgenticSystemPrompt()
        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in messages.dropLast() {
            let role = msg.role == .user ? "user" : "assistant"
            if !msg.text.isEmpty {
                apiMessages.append(["role": role, "content": msg.text])
            }
        }

        // ② Phase 1: non-streaming call with tools
        let phase1: Phase1Result
        do {
            phase1 = try await callDeepSeekWithTools(apiKey: apiKey, messages: apiMessages)
        } catch {
            logger.warning("Phase 1 failed, falling back to legacy flow: \(error.localizedDescription)")
            await fallbackStream(apiKey: apiKey, text: text, assistantID: assistantID)
            return
        }

        tts?.stop()
        ttsSentenceBuffer = ""

        switch phase1 {
        case .textResponse(let reply):
            // AI answered directly — no tool call needed
            logger.info("Phase 1: direct text response (no tool call)")
            updateAssistant(id: assistantID, text: reply)
            feedTTSFull(reply)

        case .toolCalls(let assistantMsg, let calls):
            // ③ Execute tool calls and collect results
            var toolResultMessages: [[String: Any]] = [assistantMsg]
            for call in calls {
                let result: String
                switch call.functionName {
                case "search_memory":
                    logger.info("Phase 1: AI called search_memory, query=\(call.arguments["query"] as? String ?? "?")")
                    result = await executeSearchMemory(arguments: call.arguments)
                case "who_is_visible":
                    logger.info("Phase 1: AI called who_is_visible")
                    result = executeWhoIsVisible()
                default:
                    logger.warning("Unknown tool call: \(call.functionName)")
                    result = "未知工具: \(call.functionName)"
                }
                toolResultMessages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result
                ])
            }

            // ④ Phase 2: streaming call with tool results
            let phase2Messages = apiMessages + toolResultMessages
            var fullText = ""
            do {
                let stream = try makeDeepSeekStream(apiKey: apiKey, messages: phase2Messages)
                for try await chunk in stream {
                    fullText += chunk
                    streamingText = fullText
                    updateAssistant(id: assistantID, text: fullText)
                    feedTTS(chunk: chunk)
                }
                flushTTS()
            } catch {
                logger.error("Phase 2 stream error: \(error.localizedDescription)")
                errorMessage = "AI 连接失败: \(error.localizedDescription)"
                showRetry = true
            }
        }

        memorizeUserContent(text)

        streamingText = ""
        isStreaming = false
        onStreamingFinished?()
    }

    // MARK: - Phase 1: Non-streaming call with tools

    private func callDeepSeekWithTools(
        apiKey: String,
        messages: [[String: Any]]
    ) async throws -> Phase1Result {
        let url = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 4096,
            "stream": false,
            "tools": Self.memoryTools,
            "tool_choice": "auto"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.apiError(statusCode: http.statusCode, message: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw DeepSeekError.apiError(statusCode: 0, message: "Invalid response format")
        }

        // Check for tool_calls
        if let toolCallsRaw = message["tool_calls"] as? [[String: Any]], !toolCallsRaw.isEmpty {
            var calls: [ToolCall] = []
            for tc in toolCallsRaw {
                guard let id = tc["id"] as? String,
                      let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }

                var args: [String: Any] = [:]
                if let argsStr = fn["arguments"] as? String,
                   let argsData = argsStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    args = parsed
                }
                calls.append(ToolCall(id: id, functionName: name, arguments: args))
            }

            if calls.isEmpty {
                // Malformed tool_calls — treat as text
                let text = message["content"] as? String ?? ""
                return .textResponse(text)
            }

            // Build assistant message dict for the conversation (must include tool_calls)
            var assistantMsg: [String: Any] = ["role": "assistant"]
            if let content = message["content"] { assistantMsg["content"] = content }
            assistantMsg["tool_calls"] = toolCallsRaw
            return .toolCalls(assistantMessage: assistantMsg, calls: calls)
        }

        // No tool calls — direct text response
        let text = message["content"] as? String ?? ""
        return .textResponse(text)
    }

    // MARK: - Memory retrieval from EverMemOS

    private func fetchMemoryContext(query: String) async -> String {
        guard let client = apiClient else { return "（暂无相关记忆记录）" }
        do {
            var builder = SearchMemoriesBuilder()
            builder.userId = userID
            builder.query = query
            builder.retrieveMethod = .hybrid
            builder.topK = 5
            let result = try await client.searchMemories(builder)
            return formatMemoryContext(result)
        } catch {
            logger.warning("Memory search failed, degrading: \(error.localizedDescription)")
            return "（记忆检索暂不可用）"
        }
    }

    private func formatMemoryContext(_ result: SearchResponse) -> String {
        var lines: [String] = []

        for profile in result.profiles {
            if let desc = profile.description, !desc.isEmpty {
                let category = profile.category.map { "[\($0)] " } ?? ""
                lines.append("- \(category)\(desc)")
            }
        }

        for mem in result.memories {
            let time = mem.timestamp.flatMap { formatTimestamp($0) } ?? ""
            let suffix = time.isEmpty ? "" : "（\(time)）"
            if let fact = mem.atomicFact {
                lines.append("- \(fact)\(suffix)")
            } else if let summary = mem.summary {
                lines.append("- \(summary)\(suffix)")
            }
        }

        if lines.isEmpty {
            return "（暂无相关记忆记录）"
        }
        return lines.joined(separator: "\n")
    }

    private func formatTimestamp(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 HH:mm"
        return df.string(from: date)
    }

    // MARK: - Tool Execution

    private func executeSearchMemory(arguments: [String: Any]) async -> String {
        guard let client = apiClient else {
            return "记忆系统未连接，无法搜索记忆记录。"
        }

        let query = arguments["query"] as? String ?? ""
        let topK = arguments["top_k"] as? Int ?? 5

        do {
            var builder = SearchMemoriesBuilder()
            builder.userId = userID
            builder.query = query
            builder.retrieveMethod = .hybrid
            builder.topK = topK
            let result = try await client.searchMemories(builder)
            return formatMemoryContext(result)
        } catch {
            logger.warning("search_memory tool failed: \(error.localizedDescription)")
            return "记忆检索失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Face Tool Execution

    private func executeWhoIsVisible() -> String {
        // Bypass cooldown so recognition re-triggers immediately
        faceRecognitionService?.bypassCooldown()

        guard let faces = perceptionState?.visibleFaces, !faces.isEmpty else {
            return "当前视线中没有检测到认识的人。"
        }

        let descs = faces.values.map { f in
            let rel = f.relationship.map { "（\($0)）" } ?? ""
            return "\(f.name)\(rel)，置信度\(Int(f.confidence * 100))%"
        }
        return "当前看到：" + descs.joined(separator: "；")
    }

    // MARK: - System prompt

    private func buildSystemPrompt(memoryContext: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日 HH:mm"
        let currentTime = df.string(from: Date())

        return """
        你是一位温暖、耐心的记忆助手，帮助阿尔茨海默症患者回忆日常生活。

        ## 回答规则
        1. 每次 2-3 句话，简短清晰
        2. 能回答时带上记录时间（如"今天上午10点记录的"）
        3. 耐心对待重复提问
        4. 发现未服药物时温和提醒
        5. 不提供医疗建议
        6. 没有相关记忆时明确说"我这里没有这个记录"

        ## 患者的记忆记录
        \(memoryContext)

        ## 当前时间
        \(currentTime)
        """
    }

    // MARK: - DeepSeek OpenAI-compatible streaming

    private func makeDeepSeekStream(
        apiKey: String,
        messages: [[String: Any]]
    ) throws -> AsyncThrowingStream<String, Error> {
        let url = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 4096,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                let session = URLSession(configuration: .default)
                let (bytes, response) = try await session.bytes(for: request)

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    // Try to read error body
                    var errorBody = ""
                    for try await line in bytes.lines {
                        errorBody += line
                        if errorBody.count > 500 { break }
                    }
                    throw DeepSeekError.apiError(statusCode: http.statusCode, message: errorBody)
                }

                for try await line in bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data: ") else { continue }
                    let jsonStr = String(trimmed.dropFirst(6))
                    if jsonStr == "[DONE]" { break }

                    guard let data = jsonStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let content = delta["content"] as? String else { continue }

                    continuation.yield(content)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Real-time TTS

    /// Sentence-ending punctuation for splitting (Chinese + English + newline)
    private static let sentenceEndingChars = "。！？.!?\n"

    /// Buffer streaming chunks and enqueue complete sentences for TTS
    private func feedTTS(chunk: String) {
        guard tts != nil else {
            logger.warning("TTS is nil, skipping feedTTS")
            return
        }
        ttsSentenceBuffer += chunk

        // Split on sentence boundaries, enqueue each complete sentence
        while let idx = ttsSentenceBuffer.firstIndex(where: { Self.sentenceEndingChars.contains($0) }) {
            let sentence = String(ttsSentenceBuffer[ttsSentenceBuffer.startIndex...idx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nextIdx = ttsSentenceBuffer.index(after: idx)
            ttsSentenceBuffer = String(ttsSentenceBuffer[nextIdx...])
            if !sentence.isEmpty {
                logger.debug("TTS enqueue: \(sentence)")
                tts?.enqueue(sentence)
            }
        }
    }

    /// Flush remaining buffered text to TTS
    private func flushTTS() {
        let remaining = ttsSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        ttsSentenceBuffer = ""
        if !remaining.isEmpty {
            logger.debug("TTS flush: \(remaining)")
            tts?.enqueue(remaining)
        }
    }

    /// Feed a complete text to TTS by splitting on sentence boundaries
    private func feedTTSFull(_ text: String) {
        guard tts != nil else { return }
        ttsSentenceBuffer = ""
        for char in text {
            ttsSentenceBuffer += String(char)
            if Self.sentenceEndingChars.contains(char) {
                let sentence = ttsSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                ttsSentenceBuffer = ""
                if !sentence.isEmpty {
                    tts?.enqueue(sentence)
                }
            }
        }
        // Flush remainder
        let remaining = ttsSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        ttsSentenceBuffer = ""
        if !remaining.isEmpty {
            tts?.enqueue(remaining)
        }
    }

    // MARK: - Fallback (legacy flow)

    /// Falls back to the old flow: unconditional memory fetch + streaming
    private func fallbackStream(apiKey: String, text: String, assistantID: String) async {
        let memoryContext = await fetchMemoryContext(query: text)
        let systemPrompt = buildSystemPrompt(memoryContext: memoryContext)

        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in messages.dropLast() {
            let role = msg.role == .user ? "user" : "assistant"
            if !msg.text.isEmpty {
                apiMessages.append(["role": role, "content": msg.text])
            }
        }

        var fullText = ""
        tts?.stop()
        ttsSentenceBuffer = ""
        do {
            let stream = try makeDeepSeekStream(apiKey: apiKey, messages: apiMessages)
            for try await chunk in stream {
                fullText += chunk
                streamingText = fullText
                updateAssistant(id: assistantID, text: fullText)
                feedTTS(chunk: chunk)
            }
            flushTTS()
        } catch {
            logger.error("Fallback stream error: \(error.localizedDescription)")
            errorMessage = "AI 连接失败: \(error.localizedDescription)"
            showRetry = true
        }

        memorizeUserContent(text)

        streamingText = ""
        isStreaming = false
        onStreamingFinished?()
    }

    // MARK: - Helpers

    private func updateAssistant(id: String, text: String) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].text = text
        }
    }

    private func memorizeUserContent(_ text: String, flush: Bool = false) {
        guard let client = apiClient else {
            logger.warning("[Memorize] No API client configured")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        logger.info("[Memorize] Sending: \(trimmed.prefix(50))... flush=\(flush)")
        let deviceID = DeviceIDManager.shared.deviceID
        Task.detached { [userID, groupID] in
            let augmentedUserID = DeviceIDHelper.augment(userId: userID, with: deviceID)
            let augmentedGroupID = DeviceIDHelper.augment(groupId: groupID, with: deviceID)
            let req = MemorizeRequest(
                messageId: UUID().uuidString,
                createTime: ISO8601DateFormatter().string(from: Date()),
                sender: augmentedUserID,
                content: trimmed,
                groupId: augmentedGroupID,
                groupName: "Memo 患者记忆",
                senderName: userID == "patient" ? "患者" : "照护者",
                role: userID == "patient" ? "user" : "assistant",
                flush: flush
            )
            do {
                let result = try await client.memorize(req)
                logger.info("[Memorize] Success: \(result.message ?? "ok")")
            } catch {
                logger.error("[Memorize] Failed: \(error.localizedDescription)")
            }
        }
    }

}

// MARK: - Error

enum DeepSeekError: LocalizedError {
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .apiError(let code, let msg): return "DeepSeek API 错误 (\(code)): \(msg.prefix(200))"
        }
    }
}
