import Foundation

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

        let instructions: String
        switch promptMode {
        case 0:
            instructions = "Fix all grammar and spelling errors in the following text. Do not change the tone or meaning. IMPORTANT: You must strictly preserve the original language of the text. Do NOT translate it to Russian, English, or any other language. Output ONLY the corrected text without any preamble."
        case 1:
            instructions = "Rewrite the following text to sound professional, polite, and suitable for business communication. IMPORTANT: You must strictly preserve the original language of the text. Do NOT translate it to Russian, English, or any other language. Output ONLY the revised text without any preamble."
        case 2:
            instructions = "\(customPrompt)\n\nOutput ONLY the revised text without any preamble. Preserve the original language."
        default:
            instructions = "Fix all grammar and spelling errors in the following text. Do not change the tone or meaning. IMPORTANT: You must strictly preserve the original language of the text. Do NOT translate it. Output ONLY the corrected text without any preamble."
        }

        let prompt = text
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
}
