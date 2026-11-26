import Foundation
import MetaBrainCore
import MetaBrainReferenceDNS
import Synchronization

struct ExternalURLCheck: Encodable {
    enum Status: String, Encodable {
        case reachable, redirected, notFound, restricted, inconclusive, blocked
    }

    let url: String
    let status: Status
    var httpStatus: Int? = nil
    var finalURL: String? = nil
    var reason: String? = nil

    var verified: Bool { status == .reachable || status == .redirected }
}

struct ExternalLintOutput: Encodable {
    let report: DocumentLintReport
    let externalChecks: [ExternalURLCheck]

    private enum CodingKeys: String, CodingKey { case externalChecks }

    func encode(to encoder: Encoder) throws {
        try report.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(externalChecks, forKey: .externalChecks)
    }
}

enum ExternalReferenceProbe {
    private static let urlLimit = 100
    private static let redirectLimit = 5
    private static let byteLimit = 65_536
    private static let dnsQueue = DispatchQueue(label: "metaBrain external reference resolution", qos: .utility)

    static func run(_ references: [ReferenceCheck]) -> [ExternalURLCheck] {
        var seen: Set<String> = []
        let urls = references.compactMap { reference -> String? in
            guard reference.kind == .externalURL, reference.status == .notChecked,
                  let url = withoutFragment(reference.destination), seen.insert(url).inserted else {
                return nil
            }
            return url
        }
        let curl = findCurl()
        return urls.enumerated().map { offset, url in
            guard offset < urlLimit else { return ExternalURLCheck(url: url, status: .inconclusive, reason: "requestLimit") }
            guard let curl else { return ExternalURLCheck(url: url, status: .inconclusive, reason: "curlUnavailable") }
            return check(url, at: url, redirects: 0, curl: curl)
        }
    }

    private static func withoutFragment(_ value: String) -> String? {
        var parts = URLComponents(string: value)
        parts?.fragment = nil
        return parts?.url?.absoluteString
    }

    private static func findCurl() -> URL? {
        #if os(Windows)
        let separator: Character = ";"
        let name = "curl.exe"
        #else
        let separator: Character = ":"
        let name = "curl"
        #endif
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: separator).lazy.map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name)
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func check(_ original: String, at url: String, redirects: Int, curl: URL) -> ExternalURLCheck {
        switch request(url, curl: curl) {
        case .failure(let reason):
            return ExternalURLCheck(url: original, status: reason == .unsafeDestination ? .blocked : .inconclusive,
                                    reason: reason.rawValue)
        case .success(let response):
            let code = response.code
            let final = redirects == 0 ? nil : url
            switch code {
            case 200..<300:
                return ExternalURLCheck(url: original, status: redirects == 0 ? .reachable : .redirected,
                                        httpStatus: code, finalURL: final)
            case 301, 302, 303, 307, 308:
                guard redirects < redirectLimit, let redirect = response.redirect, redirect != url else {
                    return ExternalURLCheck(url: original, status: .inconclusive, httpStatus: code,
                                            finalURL: final, reason: "missingOrExcessiveRedirect")
                }
                return check(original, at: redirect, redirects: redirects + 1, curl: curl)
            case 404, 410:
                return ExternalURLCheck(url: original, status: .notFound, httpStatus: code, finalURL: final)
            case 401, 403, 407, 451:
                return ExternalURLCheck(url: original, status: .restricted, httpStatus: code, finalURL: final)
            default:
                return ExternalURLCheck(url: original, status: .inconclusive, httpStatus: code, finalURL: final)
            }
        }
    }

    private enum Failure: String, Error {
        case unsafeDestination, dnsUnavailable, transportUnavailable
    }

    private struct HTTPResponse {
        let code: Int
        let redirect: String?
    }

    private static func request(_ value: String, curl: URL) -> Result<HTTPResponse, Failure> {
        guard ExternalReference.classify(value).status == .notChecked,
              let url = URL(string: value), let host = url.host(percentEncoded: true) else {
            return .failure(.unsafeDestination)
        }
        let address = resolve(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        return address.flatMap { address in
            let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
            let connection = address.contains(":") ? "[\(address)]" : address
            let args = [
                "--disable", "--silent", "--proxy", "", "--noproxy", "*", "--globoff",
                "--proto", "=http,https", "--connect-timeout", "3", "--max-time", "8",
                "--connect-to", "::\(connection):\(port)", "--output", FileHandle.nullDevicePath,
                "--write-out", "%{http_code}\\n%{redirect_url}"
            ]
            guard let head = curlRequest(curl, args + ["--head", "--url", value]) else {
                return .failure(.transportUnavailable)
            }
            if head.code == 405 || head.code == 501 {
                guard let ranged = curlRequest(curl, args + [
                    "--range", "0-0", "--max-filesize", String(byteLimit), "--url", value
                ]) else { return .failure(.transportUnavailable) }
                return .success(ranged)
            }
            return .success(head)
        }
    }

    private static func curlRequest(_ executable: URL, _ arguments: [String]) -> HTTPResponse? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // curl reports status 63 when the fallback GET exceeds its transfer limit.
        guard process.terminationStatus == 0 || process.terminationStatus == 63 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let first = lines.first, let code = Int(first), (100...599).contains(code) else { return nil }
        return HTTPResponse(code: code, redirect: lines.dropFirst().first.map(String.init))
    }

    private static func resolve(_ host: String) -> Result<String, Failure> {
        let result = Mutex<Result<String, Failure>>(.failure(.dnsUnavailable))
        let done = DispatchSemaphore(value: 0)
        dnsQueue.async {
            var address = [CChar](repeating: 0, count: 64)
            let status = mb_reference_resolve_public(host, &address, address.count)
            result.withLock {
                switch status {
                case MB_REFERENCE_ADDRESS_RESOLVED:
                    $0 = .success(String(decoding: address.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self))
                case MB_REFERENCE_ADDRESS_BLOCKED: $0 = .failure(.unsafeDestination)
                default: $0 = .failure(.dnsUnavailable)
                }
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 3) == .success else { return .failure(.dnsUnavailable) }
        return result.withLock { $0 }
    }
}

private extension FileHandle {
    static var nullDevicePath: String {
        #if os(Windows)
        "NUL"
        #else
        "/dev/null"
        #endif
    }
}
