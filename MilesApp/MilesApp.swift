import SwiftUI
import MilesCore

/// App shell. The library picker, root list, search bar and thumbnail grid arrive in PLAN.md Step 3.
@main
struct MilesApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Miles").font(.largeTitle)
                Text("MilesCore \(MilesCore.version)").foregroundStyle(.secondary)
            }
            .frame(minWidth: 400, minHeight: 240)
        }
    }
}
