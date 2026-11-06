import SwiftUI
import MilesCore

/// App shell: library picker, folder list, search bar and the thumbnail grid (PLAN.md Step 3).
@main
struct MilesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
