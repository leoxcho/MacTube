#if os(macOS)
import AppKit
import SwiftUI

struct MacCustomLibraryManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = MacCustomLibraryStore.shared
    @State private var selection: UUID?
    @State private var removing: MacCustomLibrary?
    init(initialSelection: UUID? = nil) { _selection = State(initialValue: initialSelection) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Custom Media Libraries").font(.title2.bold())
                Spacer()
                Button("Add Library…") { Task { await store.chooseNewLibrary() } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HSplitView {
                List(selection: $selection) {
                    ForEach(store.libraries) { library in
                        Label(library.name, systemImage: library.symbol).tag(library.id)
                            .listRowBackground(Color.clear)
                    }
                }.frame(minWidth: 190, idealWidth: 230, maxWidth: 300).scrollContentBackground(.hidden)
                ScrollView {
                    if let library = store.libraries.first(where: { $0.id == selection }) {
                        editor(library).padding(16)
                    } else {
                        Text("Select a library to edit its name, icon and folders.")
                            .foregroundStyle(.secondary).padding(30)
                    }
                }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            DisclosureGroup("Preserved indexed folders") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(MacMediaLibrary.shared.folders) { folder in
                            HStack {
                                Text(folder.url.path).font(.caption).textSelection(.enabled)
                                Spacer()
                                Button("Create Library") { store.adoptFolder(folder) }
                            }
                        }
                    }.padding(8)
                }.frame(maxHeight: 120)
                Text("Legacy source records remain indexed. Creating a library adds explicit membership without copying files.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Removing a library or folder removes its configuration only. Original files, playback, playlists and bookmarked access are preserved.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 960, maxWidth: .infinity, minHeight: 500, idealHeight: 650, maxHeight: .infinity)
        .background(MacGlassBackdrop())
        .background(MacLibrarySheetResizeHost())
        .onAppear { if selection == nil { selection = store.libraries.first?.id } }
        .confirmationDialog("Remove Library?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Library", role: .destructive) {
                if let id = removing?.id {
                    if selection == id { selection = nil }
                    store.remove(id)
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Only the MacTube configuration for “\(removing?.name ?? "")” will be removed. Files will stay on disk.") }
    }
    private func editor(_ library: MacCustomLibrary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Library name", text: Binding(get: {
                store.libraries.first(where: { $0.id == library.id })?.name ?? ""
            }, set: { store.update(library.id, name: $0) })).textFieldStyle(.roundedBorder)
            Picker("Icon", selection: Binding(get: {
                store.libraries.first(where: { $0.id == library.id })?.symbol ?? "folder"
            }, set: { store.update(library.id, symbol: $0) })) {
                ForEach(["folder", "film", "tv", "sparkles.tv", "music.note", "play.rectangle", "books.vertical"], id: \.self) { symbol in
                    Label(symbol, systemImage: symbol).tag(symbol)
                }
            }
            HStack {
                Button("Move Up") { store.move(library.id, by: -1) }
                Button("Move Down") { store.move(library.id, by: 1) }
                Spacer()
                Button("Refresh Library") { MacMediaLibrary.shared.refresh() }
            }
            HStack { Text("Folders").font(.headline); Spacer(); Button("Add Folder…") { Task { await store.addFolders(to: library.id) } } }
            ForEach(library.folderPaths, id: \.self) { path in
                VStack(alignment: .leading, spacing: 8) {
                    Text(path).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        Spacer()
                        Button("Remove Folder") { store.removeFolder(path, from: library.id) }
                    }
                }.padding(12).macGlassSurface(radius: 10)
            }
            if library.folderPaths.isEmpty { Text("Add a folder to display media in this library.").foregroundStyle(.secondary) }
            Button("Remove Library…", role: .destructive) { removing = library }
        }
    }
}

/// Context actions use stable IDs, never array-index bindings.
struct MacCustomLibraryContextMenu: View {
    let library: MacCustomLibrary
    let edit: () -> Void
    let remove: () -> Void
    private let store = MacCustomLibraryStore.shared
    var body: some View {
        Button("Rename Library…", action: edit)
        Menu("Change Icon") {
            ForEach(["folder", "film", "tv", "sparkles.tv", "music.note", "play.rectangle", "books.vertical"], id: \.self) { symbol in
                Button { store.update(library.id, symbol: symbol) } label: { Label(symbol, systemImage: symbol) }
            }
        }
        Button("Edit Folders…", action: edit)
        Button("Add Folder…") { Task { await store.addFolders(to: library.id) } }
        Button("Refresh Library") { MacMediaLibrary.shared.refresh() }
        Menu("Reveal Folder in Finder") {
            ForEach(library.folderPaths, id: \.self) { path in
                Button(path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }.disabled(library.folderPaths.isEmpty)
        Divider()
        Button("Move Up") { store.move(library.id, by: -1) }.disabled(store.libraries.first?.id == library.id)
        Button("Move Down") { store.move(library.id, by: 1) }.disabled(store.libraries.last?.id == library.id)
        Divider()
        Button("Remove Library…", role: .destructive, action: remove)
    }
}

private struct MacLibrarySheetResizeHost: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {}
    @MainActor final class Host: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.styleMask.insert(.resizable)
            window?.minSize = NSSize(width: 760, height: 500)
        }
    }
}
#endif
