import Foundation

struct AppConfig: Codable {
    var provider: String = "ollama" // "ollama" or "openai"
    var url: String = "http://localhost:11434"
    var model: String = "gemma4:e2b"

    static let configPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".draftscript_config.json")

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configPath),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: AppConfig.configPath)
    }
}

var currentConfig: AppConfig = AppConfig.load()
