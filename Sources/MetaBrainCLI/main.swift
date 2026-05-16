import ArgumentParser
import MetaBrainCore

@main
struct MetaBrainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metabrain",
        abstract: "Run metaBrain from the command line."
    )

    @Argument(help: "Text to send to the shared MetaBrain core.")
    var prompt: String = ""

    func run() throws {
        let brain = MetaBrain()
        print(brain.respond(to: prompt))
    }
}
