import SwiftUI

@main
struct MetaBrainApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandMenu("Database") {
                Button("Open Database...") {
                    NotificationCenter.default.post(
                        name: .metaBrainOpenDatabaseRequested,
                        object: nil
                    )
                }
                .keyboardShortcut("o")
            }

            CommandGroup(after: .textEditing) {
                Button("Find in metaBrain") {
                    NotificationCenter.default.post(
                        name: .metaBrainFindRequested,
                        object: nil
                    )
                }
                .keyboardShortcut("f")
            }
        }
    }
}

extension Notification.Name {
    static let metaBrainOpenDatabaseRequested = Notification.Name("MetaBrainOpenDatabaseRequested")
    static let metaBrainFindRequested = Notification.Name("MetaBrainFindRequested")
}
