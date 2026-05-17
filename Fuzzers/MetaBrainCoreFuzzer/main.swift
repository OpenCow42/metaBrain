import Foundation
import MetaBrainCore

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzMetaBrainCore(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let bytes = UnsafeRawBufferPointer(start: start, count: count)
    guard count > 0, count <= 16_384 else {
        return 0
    }

    let data = Data(bytes)
    exerciseCodableDecoders(with: data)

    guard let text = String(data: data, encoding: .utf8) else {
        return 0
    }

    exerciseDomainParsers(with: text)
    exercisePatchParser(with: text)
    return 0
}

private func exerciseDomainParsers(with text: String) {
    _ = try? DocumentPath.normalized(text)
    _ = try? DocumentPath(text)
    _ = try? DocumentID(rawValue: text)

    for line in text.split(whereSeparator: \.isNewline).prefix(8) {
        let value = String(line)
        _ = try? DocumentPath.normalized(value)
        _ = try? DocumentID(rawValue: value)
    }
}

private func exercisePatchParser(with text: String) {
    guard let patch = try? UnifiedTextPatch(text) else {
        return
    }

    _ = try? patch.applying(to: "alpha\nbeta\ngamma\n")
    _ = try? patch.applying(to: "")
}

private func exerciseCodableDecoders(with data: Data) {
    let decoder = JSONDecoder()

    _ = try? decoder.decode(DocumentInput.self, from: data)
    _ = try? decoder.decode(SearchQuery.self, from: data)
    _ = try? decoder.decode(TreeQuery.self, from: data)
    _ = try? decoder.decode(DocumentDumpQuery.self, from: data)
    _ = try? decoder.decode(PruneRequest.self, from: data)
}
