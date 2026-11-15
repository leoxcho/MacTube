#if os(macOS)
import SwiftUI

struct MacControlsSettingsView: View {
    @State private var store = MacInputBindings.shared
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search controls", text: $query).textFieldStyle(.roundedBorder)
            Text("Select Record, then press a key combination or an additional mouse button. Normal typing, left/right clicks, scrolling and macOS shortcuts remain available.")
                .font(.caption).foregroundStyle(.secondary)
            if let action = store.recording {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recording: \(action.title)").font(.headline)
                    Text(store.pending?.display ?? "Waiting for keyboard or mouse input…")
                    if let message = store.message { Text(message).foregroundStyle(.orange).font(.caption) }
                    HStack {
                        Button("Save") { store.save() }.disabled(store.pending == nil || store.message != nil)
                        if let binding = store.pending, store.reservation(binding) == nil, store.message != nil {
                            Button("Replace Conflict") { store.save(replacing: true) }
                        }
                        Button("Cancel") { store.cancel() }
                    }
                }.padding(12).macGlassSurface(radius: 12)
            } else if let message = store.message { Text(message).foregroundStyle(.orange).font(.caption) }
            ForEach(MacInputAction.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { action in
                HStack {
                    Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 3) {
                        ForEach(Array(store.assigned(action).enumerated()), id: \.offset) { item in
                            HStack(spacing: 5) {
                                Text(item.element.display).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Button { store.clear(item.element, for: action) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("Clear \(item.element.display) from \(action.title)")
                            }
                        }
                    }
                    Button("Record") { store.begin(action) }
                    Button("Clear") { store.clear(action) }.disabled(store.assigned(action).isEmpty)
                    Button("Default") { store.restore(action) }
                }.padding(.vertical, 3)
            }
            Button("Reset All Controls to Defaults") { store.reset() }
            Text("Mouse Buttons 4 and 5 default to Back and Forward. Some device drivers intercept extra buttons before MacTube receives them. Bindings use physical key positions. macOS media keys continue using the existing system media integration.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { store.cancel() }
    }
}
#endif
