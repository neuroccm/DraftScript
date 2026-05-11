import Foundation

struct LLMService {
    static var model: String = {
        ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "gemma4:e2b"
    }()
    private static let baseURL = "http://localhost:11434"

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
        guard let data = try? runCurl(args: ["-s", "--connect-timeout", "2", "--max-time", "5", "\(baseURL)/api/tags"]),
              !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
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

        Answer the user's question using only the draft content above.
        If the question asks for a comparison, extract the evidence for each compared item separately before concluding.
        If one item has a value and the other item is missing that value, say that clearly and include the known value.
        Do not say all data is missing if partial values are present.
        Do not confuse similarly named products; preserve exact product names from the drafts.
        If exact sizes differ, state the size caveat before comparing.
        Compute the answer from the values in the drafts and state the conclusion clearly when enough evidence exists.
        Cite the supporting draft numbers and UUID prefixes inline.
        Preserve important numeric values, model names, product names, dates, and qualifiers.
        If the drafts do not contain enough evidence, say exactly what is missing.
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            "options": ["num_predict": 2048]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("draftscript_llm_\(UUID().uuidString).json")
        try jsonData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try runCurl(args: [
            "-s", "--max-time", "60",
            "-X", "POST",
            "\(baseURL)/api/chat",
            "-H", "Content-Type: application/json",
            "-d", "@\(tempURL.path)"
        ])

        guard !result.isEmpty else {
            throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty response from Ollama"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else {
            throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON from Ollama: \(result.prefix(200))"])
        }

        if let errMsg = json["error"] as? String {
            throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg])
        }

        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response format from Ollama"])
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
