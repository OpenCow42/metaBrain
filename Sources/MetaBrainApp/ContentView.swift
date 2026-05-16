import MetaBrainCore
import SwiftUI

struct ContentView: View {
    private let brain = MetaBrain()

    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("metaBrain")
                .font(.largeTitle.bold())

            TextField("Ask something", text: $prompt)
                .textFieldStyle(.roundedBorder)

            Text(brain.respond(to: prompt))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(minWidth: 420, minHeight: 220)
    }
}
