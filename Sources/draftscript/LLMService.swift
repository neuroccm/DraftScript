import Foundation

struct LLMService {
    static let model = "gemma4:e2b"
    private static let baseURL = "http://localhost:11434"

    static var isAvailable: Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["--connect-timeout", "2", "--max-time", "3", "-s", "-o", "/dev/null", "-w", "%{http_code}", "\(baseURL)/api/tags"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = nil
        try? proc.run()
        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let code = String(data: data, encoding: .utf8) ?? ""
        return code == "200"
    }

    static func searchDrafts(query: String, drafts: [(uuid: String, content: String)]) throws -> String {
        let limited = drafts.prefix(50)

        let draftsText = limited.enumerated().map { (i, d) -> String in
            "[\(i + 1)] \(d.uuid.prefix(8)): \(d.content.prefix(300).replacingOccurrences(of: "\n", with: " "))"
        }.joined(separator: "\n\n")

        let prompt = """
        You have a collection of notes/drafts. Find the ones most relevant to this search query: "\(query)"

        Drafts:
        \(draftsText)

        Return the numbers of the most relevant drafts (max 5) with a brief reason for each.
        If nothing is relevant, say so.
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

        var request = URLRequest(url: URL(string: "\(baseURL)/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 60

        let semaphore = DispatchSemaphore(value: 0)
        var result: String = ""
        var error: Error?

        URLSession.shared.dataTask(with: request) { data, _, err in
            if let err = err {
                error = err
                semaphore.signal()
                return
            }
            guard let data = data else {
                error = NSError(domain: "LLMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data"])
                semaphore.signal()
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                result = content
            } else if let errMsg = String(data: data, encoding: .utf8) {
                result = errMsg
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let error = error {
            throw error
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
