#if os(macOS)
import SmartTubeIOSCore
import SwiftUI

/// Local history and already-fetched suggestions; focusing never starts a request.
struct MacSearchHistoryMenu: View {
    let query: String
    var suggestions: [String] = []
    let onSelect: (String) -> Void
    @State private var history: [SearchHistoryEntry] = []

    private var matchingHistory: [SearchHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? history : history.filter { $0.query.localizedCaseInsensitiveContains(trimmed) }
    }

    private var matchingSuggestions: [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let existing = Set(matchingHistory.map { $0.query.lowercased() })
        return Array(suggestions.filter { !existing.contains($0.lowercased()) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent searches").font(.headline)
                Spacer()
                Button("Clear Search History") {
                    Task { await SearchHistoryStore.shared.clear(); history = [] }
                }
                .disabled(history.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(matchingHistory) { entry in
                        HStack {
                            Button { onSelect(entry.query) } label: {
                                Label(entry.query, systemImage: "clock")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                Task {
                                    await SearchHistoryStore.shared.remove(entry.query)
                                    history = await SearchHistoryStore.shared.all
                                }
                            } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(entry.query) from search history")
                        }
                        .padding(.vertical, 4)
                    }
                    if !matchingSuggestions.isEmpty {
                        Text("Suggestions").font(.caption).foregroundStyle(.secondary)
                        ForEach(matchingSuggestions, id: \.self) { suggestion in
                            Button { onSelect(suggestion) } label: {
                                Label(suggestion, systemImage: "magnifyingglass")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).padding(.vertical, 4)
                        }
                    }
                    if matchingHistory.isEmpty && matchingSuggestions.isEmpty {
                        Text("Submitted searches appear here.").foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(16).frame(width: 420)
        .task(id: query) { history = await SearchHistoryStore.shared.all }
    }
}
#endif
