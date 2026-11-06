import AppKit
import MilesCore
import SwiftUI

/// AI suggestions waiting for the user (ADR 0003, 0010). Accepting makes the tag searchable; rejecting keeps it
/// from being suggested again for that file.
struct ReviewQueueView: View {
    @Bindable var model: AppModel
    @State private var threshold = 0.8

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.suggestionCount) suggestions to review").font(.headline)
                Spacer()
                Stepper(value: $threshold, in: 0.1...1, step: 0.05) {
                    Text("Accept all at or above \(threshold, format: .number.precision(.fractionLength(2)))")
                        .monospacedDigit()
                }
                Button("Accept") { model.acceptAll(minConfidence: threshold) }
                    .disabled(model.suggestions.isEmpty)
            }
            .padding(12)
            Divider()
            if model.suggestions.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                       description: Text("Suggestions from the on-device models appear here. Tags you accept become searchable."))
            } else {
                List(model.suggestions) { suggestion in
                    row(suggestion)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear { model.reloadSuggestions() }
    }

    private func row(_ s: Suggestion) -> some View {
        HStack(spacing: 10) {
            Group {
                if let image = NSImage(contentsOfFile: model.thumbnailPath(for: s.fileID)) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.tag.display).font(.body.weight(.medium))
                Text((s.relativePath as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let c = s.confidence { Text(c, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                Text(s.provider ?? "").font(.caption).foregroundStyle(.secondary)
            }
            .help("\(s.provider ?? "?") / \(s.model ?? "?")")
            Button("Accept", systemImage: "checkmark") { model.decide(s, accept: true) }.labelStyle(.iconOnly)
            Button("Reject", systemImage: "xmark") { model.decide(s, accept: false) }.labelStyle(.iconOnly)
        }
    }
}

/// Plain-language search: shows the query the on-device model wrote, editable, and runs it only when asked (ADR 0015).
struct AskView: View {
    @Bindable var model: AppModel
    @State private var request = ""
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe what you are looking for").font(.headline)
            TextField("pictures from this year bigger than 5 MB", text: $request)
                .onSubmit { model.translate(request) }
            if model.translating { ProgressView().controlSize(.small) }
            if let t = model.translation {
                Text("Miles will search for:").font(.subheadline).foregroundStyle(.secondary)
                TextField("Query", text: $query).font(.body.monospaced())
                    .onSubmit { run() }
                    .onAppear { query = t.query }
                    .onChange(of: t.query) { _, new in query = new }
                Text("Written by the on-device model, which can get it wrong. Edit it if needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.translation = nil; dismiss() }
                if model.translation == nil {
                    Button("Write Query") { model.translate(request) }
                        .keyboardShortcut(.defaultAction).disabled(request.isEmpty || model.translating)
                } else {
                    Button("Search") { run() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16).frame(width: 460)
    }

    private func run() {
        model.runTranslation(query)
        dismiss()
    }
}
