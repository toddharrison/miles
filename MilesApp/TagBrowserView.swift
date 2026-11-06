import MilesCore
import SwiftUI

/// Every tag in the library with its file count. Clicking one searches for it.
struct TagBrowserView: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter tags", text: $filter).textFieldStyle(.roundedBorder).padding(10)
            Divider()
            if shown.isEmpty {
                ContentUnavailableView(model.allTags.isEmpty ? "No tags yet" : "No matching tags", systemImage: "tag")
            } else {
                List(shown) { info in
                    Button {
                        model.search(tag: info.name)
                        isPresented = false
                    } label: {
                        HStack {
                            Text(info.name.display)
                            Spacer()
                            Text(info.fileCount.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 320, height: 420)
        .onAppear { model.reloadTags() }
    }

    private var shown: [TagInfo] {
        let typed = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return typed.isEmpty ? model.allTags : model.allTags.filter { $0.name.display.lowercased().contains(typed) }
    }
}
