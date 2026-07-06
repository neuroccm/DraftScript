import Foundation

struct LLMService {
    static var model: String { currentConfig.model }
    static var provider: String { currentConfig.provider }
    static var baseURL: String { currentConfig.url }

    @discardableResult private static func runCurl(args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "curl failed"
            throw NSError(domain: "LLMService", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var isAvailable: Bool {
        if provider == "ollama" {
            guard let data = try? runCurl(args: ["-s", "--connect-timeout", "2", "--max-time", "5", "\(baseURL)/api/tags"]),
                   !data.isEmpty,
                   let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                   let models = json["models"] as? [[String: Any]] else { return false }
            return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
        } else {
            // For OpenAI/LM Studio, we check /v1/models
            guard let data = try? runCurl(args: ["-s", "--connect-timeout", "2", "--max-time", "5", "\(baseURL)/v1/models"]),
                   !data.isEmpty else { return false }
            return true
        }
    }

    static func fetchActiveModel() -> String? {
        do {
            if provider == "ollama" {
                let data = try runCurl(args: ["-s", "--connect-timeout", "2", "--max-time", "5", "\(baseURL)/api/tags"])
                guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                      let models = json["models"] as? [[String: Any]],
                      let firstModel = models.first,
                      let name = firstModel["name"] as? String else { return nil }
                return name
            } else {
                let data = try runCurl(args: ["-s", "--connect-timeout", "2", "--max-time", "5", "\(baseURL)/v1/models"])
                guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                      let models = json["data"] as? [[String: Any]],
                      let firstModel = models.first,
                      let id = firstModel["id"] as? String else { return nil }
                return id
            }
        } catch {
            return nil
        }
    }

    static func searchDrafts(query: String, drafts: [(uuid: String, content: String)]) throws -> String {
        let limited = drafts.prefix(8)

        let draftsText = limited.enumerated().map { (i, d) -> String in
            let content = d.content.prefix(4_000).replacingOccurrences(of: "\n", with: " ")
            return """
            [\(i + 1)] UUID \(d.uuid.prefix(8))
            \(content)
            """
        }.joined(separator: "\n\n")

        let prompt = """
        You are searching and synthesizing a user's Drafts notes.

        User question:
        \(query)

        Drafts:
        \(draftsText)

        Provide your answer as a cohesive narrative summary based only on the draft content above. 
        Avoid simple bulleted lists unless necessary for clarity; instead, weave the information into a natural, flowing response.

        If the question asks for a comparison, extract the evidence for each compared item separately before concluding.
        If one item has a value and the other item is missing that value, say that clearly and include the known value.
        Do not say all data is missing if partial values are present.
        Do not confuse similarly named products; preserve exact product names from the drafts.
        If exact sizes differ, state the size caveat before comparing.
        Compute the answer from the values in the drafts and state the conclusion clearly when enough evidence exists.
        Cite the supporting draft numbers and UUID prefixes inline (e.g., [1] 8A2B).
        Preserve important numeric values, model names, product names, dates, and qualifiers.
        If the drafts do not contain enough evidence, say exactly what is missing.
        """

        let body: [String: Any]
        let endpoint: String

        if provider == "ollama" {
            endpoint = "\(baseURL)/api/chat"
            body = [
                "model": model,
                "messages": [["role": "user", "content": prompt]],
                "stream": false,
                "options": ["num_predict": 2048]
            ]
        } else {
            endpoint = "\(baseURL)/v1/chat/completions"
            body = [
                "model": model,
                "messages": [["role": "user", "content": prompt]],
                "stream": false,
                "max_tokens": 2048
            ]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("draftscript_llm_\(UUID().uuidString).json")
        try jsonData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try runCurl(args: [
            "-s", "--max-time", "60",
            "-X", "POST",
            endpoint,
            "-H", "Content-Type: application/json",
            "-d", "@\(tempURL.path)"
        ])

        guard !result.isEmpty else {
            throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty response from \(provider)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else {
            throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON from \(provider): \(result.prefix(200))"])
        }

        if let errMsg = json["error"] as? String {
            throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }

        if provider == "ollama" {
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response format from Ollama"])
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response format from \(provider)"])
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

