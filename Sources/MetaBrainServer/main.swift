import ArgumentParser
import Foundation
import MetaBrainServerSupport

@main
struct MetaBrainDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mbd",
        abstract: "Run the metaBrain local daemon.",
        subcommands: [
            Version.self,
        ]
    )

    func run() throws {
        print(Self.helpMessage())
    }
}

extension MetaBrainDaemonCommand {
    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Print the metaBrain daemon version."
        )

        func run() throws {
            let output = VersionOutput(
                currentTag: MetaBrainVersion.currentSoftwareTag(),
                releaseCheck: nil
            )
            let data = try MetaBrainJSON.encoder().encode(output)
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
