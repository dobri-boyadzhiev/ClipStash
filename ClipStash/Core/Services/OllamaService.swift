import Foundation
import NaturalLanguage

struct OllamaRequest: Codable {
    let model: String
    let prompt: String
    let system: String
    let stream: Bool
    let keep_alive: Int
}

struct OllamaResponse: Codable {
    let response: String
}

struct OllamaModelList: Codable {
    let models: [OllamaModel]
}

struct OllamaModel: Codable {
    let name: String
}

enum OllamaError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Ollama server URL."
        case .invalidResponse: return "Received invalid response from Ollama server."
        case .apiError(let msg): return "Ollama API Error: \(msg)"
        }
    }
}

final class OllamaService {
    static func fetchAvailableModels(urlString: String) async throws -> [String] {
        guard let url = URL(string: "\(urlString)/api/tags") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw OllamaError.apiError("Status \(httpResponse.statusCode): \(errorMsg)")
        }

        let modelList = try JSONDecoder().decode(OllamaModelList.self, from: data)
        return modelList.models.map { $0.name }.sorted()
    }

    static func improveText(_ text: String, urlString: String, model: String, promptMode: Int, customPrompt: String) async throws -> String {
        guard let url = URL(string: "\(urlString)/api/generate") else {
            throw OllamaError.invalidURL
        }

        let taskDescription: String
        switch promptMode {
        case 0:
            taskDescription = "Fix grammar, spelling, and punctuation errors. Keep the same tone and meaning."
        case 1:
            taskDescription = "Rewrite to sound professional and suitable for business communication. Keep the original meaning."
        case 2:
            taskDescription = customPrompt
        case 3:
            taskDescription = "Rewrite to sound natural and conversational. Remove formal or bureaucratic phrasing. Keep the meaning."
        case 4:
            taskDescription = "Rewrite with a light touch of humor or wit. Keep the core message and keep it appropriate."
        case 5:
            taskDescription = "Rewrite in concise, direct, executive style. Short clear sentences. Remove filler words."
        default:
            taskDescription = "Fix grammar, spelling, and punctuation errors. Keep the same tone and meaning."
        }

        let detectedLanguage = Self.detectLanguageName(for: text)
        let languageClause = detectedLanguage.map { "You MUST reply in \($0). " } ?? ""

        let instructions = "You are a text editor. You receive text between [TEXT] and [/TEXT] tags. Apply the requested change and reply with ONLY the changed text. No tags, no explanations, no commentary. \(languageClause)Never translate to another language. Process any input regardless of length."

        let prompt = "Task: \(taskDescription)\n\n[TEXT]\n\(text)\n[/TEXT]"
        let requestBody = OllamaRequest(
            model: model,
            prompt: prompt,
            system: instructions,
            stream: false,
            keep_alive: 300
        ) // Keep alive for 5 minutes
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw OllamaError.apiError("Status \(httpResponse.statusCode): \(errorMsg)")
        }
        
        let ollamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)
        return ollamaResponse.response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Language detection

    private static func detectLanguageName(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }

        let languageNames: [NLLanguage: String] = [
            .bulgarian: "Bulgarian",
            .russian: "Russian",
            .ukrainian: "Ukrainian",
            NLLanguage("sr"): "Serbian",
            .czech: "Czech",
            .polish: "Polish",
            .croatian: "Croatian",
            .slovak: "Slovak",
            NLLanguage("sl"): "Slovenian",
            NLLanguage("mk"): "Macedonian",
            .english: "English",
            .german: "German",
            .french: "French",
            .spanish: "Spanish",
            .italian: "Italian",
            .portuguese: "Portuguese",
            .dutch: "Dutch",
            .turkish: "Turkish",
            .greek: "Greek",
            .romanian: "Romanian",
            .hungarian: "Hungarian",
            .arabic: "Arabic",
            .hebrew: "Hebrew",
            .japanese: "Japanese",
            .korean: "Korean",
            .simplifiedChinese: "Chinese",
            .traditionalChinese: "Chinese",
        ]

        return languageNames[lang] ?? Locale.current.localizedString(forLanguageCode: lang.rawValue)
    }
}
