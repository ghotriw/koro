import SwiftUI
import SwiftData

enum EntryEditMode {
    case create(Folder, onCreate: (Entry) -> Void)
    case edit(Entry)
}

struct EntryEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let mode: EntryEditMode

    @State private var title: String
    @State private var bodyText: String

    init(folder: Folder, onCreate: @escaping (Entry) -> Void = { _ in }) {
        self.mode = .create(folder, onCreate: onCreate)
        _title = State(initialValue: "")
        _bodyText = State(initialValue: "")
    }

    init(entry: Entry) {
        self.mode = .edit(entry)
        _title = State(initialValue: entry.title)
        _bodyText = State(initialValue: entry.body)
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $title)
                .font(.title3)
                .padding(.horizontal)
                .padding(.vertical, 12)

            Divider()

            TextEditor(text: $bodyText)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(isEditMode ? "Edit Entry" : "New Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditMode ? "Save" : "Add") {
                    save()
                    dismiss()
                }
                .disabled(title.isEmpty || bodyText.isEmpty)
            }
        }
    }

    private func save() {
        switch mode {
        case .create(let folder, let onCreate):
            let maxOrder = folder.entries.map { $0.sortOrder }.max() ?? -1
            let newEntry = Entry(title: title, body: bodyText, sortOrder: maxOrder + 1, folder: folder)
            newEntry.bodyHash = FileHashing.sha256(string: bodyText)
            modelContext.insert(newEntry)
            onCreate(newEntry)

        case .edit(let entry):
            let titleChanged = entry.title != title
            let bodyChanged = entry.body != bodyText

            if titleChanged {
                entry.title = title
            }
            if bodyChanged {
                entry.body = bodyText
                invalidateAudio(for: entry)
                entry.bodyHash = FileHashing.sha256(string: bodyText)
            }
            if titleChanged || bodyChanged {
                entry.markAsUpdated()
            }
        }
    }

    private func invalidateAudio(for entry: Entry) {
        if let oldURL = entry.audioFileURL {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let resolved = docs.appendingPathComponent(oldURL.lastPathComponent)
            try? fm.removeItem(at: resolved)
        }
        entry.tokens = nil
        entry.audioFileURL = nil
        entry.audioHash = nil
        entry.fileSize = nil
        entry.lastPosition = nil
    }
}
