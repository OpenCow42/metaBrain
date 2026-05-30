import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MetaBrainVersion {
    public static let bundledTag = "1.1.2"

    public static func currentSoftwareTag(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["METABRAIN_VERSION"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }

        return bundledTag
    }
}

public enum MetaBrainReleaseChecker {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static func checkLatestRelease(
        currentTag: String,
        releaseAPIURL: String,
        timeout: TimeInterval,
        fetch: Fetch? = nil
    ) async -> ReleaseCheckOutput {
        guard let url = URL(string: releaseAPIURL) else {
            return ReleaseCheckOutput(
                htmlURL: nil,
                latestTag: nil,
                message: "Invalid GitHub releases URL.",
                status: "failed",
                updateAvailable: nil
            )
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("metaBrain-cli", forHTTPHeaderField: "User-Agent")

        do {
            let fetch = fetch ?? defaultFetch
            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ReleaseCheckOutput(
                    htmlURL: nil,
                    latestTag: nil,
                    message: "GitHub releases response was not HTTP.",
                    status: "failed",
                    updateAvailable: nil
                )
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                return ReleaseCheckOutput(
                    htmlURL: nil,
                    latestTag: nil,
                    message: "GitHub releases request returned HTTP \(httpResponse.statusCode).",
                    status: "failed",
                    updateAvailable: nil
                )
            }

            let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
            let updateAvailable = isReleaseTag(release.tagName, newerThan: currentTag)
            return ReleaseCheckOutput(
                htmlURL: release.htmlURL,
                latestTag: release.tagName,
                message: nil,
                status: "checked",
                updateAvailable: updateAvailable
            )
        } catch {
            return ReleaseCheckOutput(
                htmlURL: nil,
                latestTag: nil,
                message: error.localizedDescription,
                status: "failed",
                updateAvailable: nil
            )
        }
    }

    public static func isReleaseTag(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = semanticVersionParts(candidate)
        let currentParts = semanticVersionParts(current)

        if candidateParts.count == 3, currentParts.count == 3 {
            return candidateParts.lexicographicallyPrecedes(currentParts) == false && candidateParts != currentParts
        }

        return candidate != current
    }

    public static func semanticVersionParts(_ tag: String) -> [Int] {
        let normalized = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let core = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)

        guard parts.count == 3 else {
            return []
        }

        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part) else {
                return []
            }
            numbers.append(number)
        }

        return numbers
    }

    private static func defaultFetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

private struct GitHubReleaseResponse: Decodable {
    let htmlURL: String?
    let tagName: String

    private enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
        case tagName = "tag_name"
    }
}
