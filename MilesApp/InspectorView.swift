import MilesCore
import SwiftUI

/// Tags on the selected file or files, grouped by namespace, with where each came from. Tags are added and
/// removed by hand here (source `user`). Removing a rule or AI tag marks it rejected, so it does not come back.
struct InspectorView: View {
    @Bindable var model: AppModel
    @State private var newTag = ""

    var body: some View {
        let count = model.selectedFileIDs.count
        Form {
            if count == 0 {
                ContentUnavailableView("No file selected", systemImage: "tag",
                                       description: Text("Select a file to see and edit its tags. Select several to tag them together."))
            } else {
                Section(header: Text(title(count))) {
                    if count == 1, let file = model.selectedFiles.first { details(file) }
                }
                addField(count: count)
                if !model.selectionTagsListed {
                    Text("Too many files are selected to list their tags. You can still add a tag to all of them.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if model.selectionTags.isEmpty {
                    Text("No tags yet").foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.namespace) { group in
                    Section(group.namespace) {
                        ForEach(group.tags) { tag in row(tag, of: count) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
    }

    private func title(_ count: Int) -> String {
        count == 1 ? ((model.selectedFiles.first?.relativePath as NSString?)?.lastPathComponent ?? "File") : "\(count.formatted()) files"
    }

    @ViewBuilder private func details(_ file: IndexedFile) -> some View {
        LabeledContent("Kind", value: file.kind ?? "other")
        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
        LabeledContent("Modified", value: file.modified.formatted(date: .abbreviated, time: .shortened))
        LabeledContent("Path") { Text(file.relativePath).textSelection(.enabled).lineLimit(3).truncationMode(.middle) }
        if file.icloudStatus == "dataless" { Label("In iCloud, not downloaded", systemImage: "icloud") }
    }

    private var grouped: [(namespace: String, tags: [SelectionTag])] {
        Dictionary(grouping: model.selectionTags, by: \.name.namespace)
            .map { (namespace: $0.key, tags: $0.value) }
            .sorted { $0.namespace < $1.namespace }
    }

    private func row(_ tag: SelectionTag, of selected: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.name.value)
                    .foregroundStyle(tag.status == "accepted" ? .primary : .secondary)
                Text(detail(tag, of: selected)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Search", systemImage: "magnifyingglass") { model.search(tag: tag.name) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Search for this tag")
            Button("Remove", systemImage: "minus.circle") { model.removeTag(tag.name) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.tagBusy)
                .help(tag.source == "user" ? "Remove this tag" : "Remove this tag and do not suggest it again")
        }
    }

    private func detail(_ tag: SelectionTag, of selected: Int) -> String {
        var parts = [sourceName(tag.source)]
        if let c = tag.confidence { parts.append(c.formatted(.percent.precision(.fractionLength(0)))) }
        if tag.status != "accepted" { parts.append("suggested") }
        if selected > 1 { parts.append("on \(tag.count) of \(selected)") }
        return parts.joined(separator: " · ")
    }

    private func sourceName(_ source: String) -> String {
        switch source {
        case "user": "added by you"
        case "rule": "from a rule"
        case "ai": "from AI"
        case "mixed": "mixed sources"
        default: source
        }
    }

    // MARK: Adding

    private func addField(count: Int) -> some View {
        Section {
            TextField("Add a tag", text: $newTag, prompt: Text(count > 1 ? "Add a tag to \(count) files" : "Add a tag, e.g. cat or place:paris"))
                .onSubmit { add(newTag) }
            ForEach(completions, id: \.id) { info in
                Button { add(info.name.display) } label: {
                    HStack {
                        Text(info.name.display)
                        Spacer()
                        Text(info.fileCount.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Existing tags that contain what is typed, most used first.
    private var completions: [TagInfo] {
        let typed = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return [] }
        return Array(model.allTags.filter { $0.name.display.lowercased().contains(typed) && $0.name.display.lowercased() != typed }
            .sorted { $0.fileCount > $1.fileCount }.prefix(6))
    }

    private func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.addTag(trimmed)
        newTag = ""
    }
}

extension TagInfo: @retroactive Identifiable {}
