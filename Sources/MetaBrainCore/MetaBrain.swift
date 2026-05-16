import Foundation

public struct MetaBrain {
    public init() {}

    public func respond(to prompt: String) -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedPrompt.isEmpty {
            return "MetaBrain is ready."
        }

        return "MetaBrain heard: \(trimmedPrompt)"
    }
}
