//
//  AddBookmarkView.swift
//  Cherry Browser
//

import SwiftUI

struct AddBookmarkView: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL
    let pageTitle: String
    let favicon: NSImage?
    let onSave: (String, String?, Bool) -> Void

    @State private var title: String = ""
    @State private var selectedFolder: String? = nil
    @State private var addToBookmarkBar: Bool = false
    @State private var newFolderName: String = ""
    @State private var showingNewFolder: Bool = false

    @Bindable var repository = BookmarkRepository.shared

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                if let favicon = favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(SettingsManager.shared.accentColor)
                }

                VStack(alignment: .leading) {
                    Text("Add Bookmark")
                        .font(.headline)
                    Text(url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            Divider()

            // Form
            VStack(alignment: .leading, spacing: 12) {
                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Bookmark name", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                // Folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Picker("", selection: $selectedFolder) {
                            Text("None").tag(nil as String?)
                            ForEach(repository.folders, id: \.self) { folder in
                                Text(folder).tag(folder as String?)
                            }
                        }
                        .labelsHidden()

                        Button(action: { showingNewFolder = true }) {
                            Image(systemName: "folder.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New Folder")
                    }
                }

                // Bookmark bar toggle
                Toggle("Add to Bookmark Bar", isOn: $addToBookmarkBar)
                    .toggleStyle(.checkbox)
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave(title, selectedFolder, addToBookmarkBar)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            title = pageTitle
        }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderView { folderName in
                repository.createFolder(name: folderName)
                selectedFolder = folderName
            }
        }
    }
}

struct NewFolderView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String) -> Void

    @State private var folderName: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    onCreate(folderName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}

#Preview {
    AddBookmarkView(
        url: URL(string: "https://www.apple.com")!,
        pageTitle: "Apple",
        favicon: nil,
        onSave: { _, _, _ in }
    )
}
