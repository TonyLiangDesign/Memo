import Foundation
import UIKit
import CoreImage
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.Memo", category: "GeminiMedication")

/// Result from Gemini item recognition
struct GeminiItemResult: Equatable {
    let item: String
    let emoji: String
    let description: String
}

/// Gemini-driven item recognition: analyzes camera frames via Gemini Flash
@Observable @MainActor
final class GeminiMedicationService {
    private let apiKeyStore: APIKeyStore

    init(apiKeyStore: APIKeyStore) {
        self.apiKeyStore = apiKeyStore
    }

    /// Analyze a CVPixelBuffer (from ARFrame) and return recognized item info
    func analyzeFrame(_ pixelBuffer: CVPixelBuffer) async -> GeminiItemResult? {
        guard let jpegData = pixelBufferToJPEG(pixelBuffer) else { return nil }
        guard let apiKey = apiKeyStore.geminiAPIKey else { return nil }

        do {
            let text = try await callGeminiItemJSON(imageData: jpegData, apiKey: apiKey)
            let result = parseItemJSON(text)
            logger.info("Gemini item: \(result.emoji) \(result.item)")
            return result
        } catch {
            logger.error("Gemini API error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Gemini API

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]
            }
            let content: Content
        }
        let candidates: [Candidate]?
    }

    private func callGeminiItemJSON(imageData: Data, apiKey: String) async throws -> String {
        let base64 = imageData.base64EncodedString()
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)")!

        let prompt = """
        你是阿尔茨海默症患者的看护助手。识别画面中最显眼的物品。
        返回JSON格式：{"item": "物品中文名", "emoji": "一个对应emoji", "description": "简短场景描述"}
        如果没有明显物品，返回：{"item": "未知", "emoji": "📍", "description": "无明显物品"}
        只返回JSON，不要其他内容。
        """

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inlineData": ["mimeType": "image/jpeg", "data": base64]]
                ]
            ]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        return response.candidates?.first?.content.parts.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "{}"
    }

    private func parseItemJSON(_ text: String) -> GeminiItemResult {
        var cleaned = text
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let item = json["item"], let emoji = json["emoji"], let desc = json["description"]
        else {
            return GeminiItemResult(item: "未知", emoji: "📍", description: text)
        }
        return GeminiItemResult(item: item, emoji: emoji, description: desc)
    }

    // MARK: - Image Conversion

    private func pixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.5)
    }
}
