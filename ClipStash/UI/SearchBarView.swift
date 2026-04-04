import SwiftUI

/// Search field with clear button and magnifying glass icon.
struct SearchBarView: View {
    @Binding var text: String
    let activeFilterCount: Int
    let recentApps: [String]
    let onApplyQuickFilter: (SearchQuickFilter) -> Void
    let onApplyRecentAppFilter: (String) -> Void
    let onClearFilters: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            
            TextField("Search clipboard history…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }

            Menu {
                Section("Content") {
                    ForEach(SearchQuickFilter.contentCases, id: \.rawValue) { filter in
                        Button {
                            onApplyQuickFilter(filter)
                        } label: {
                            Label(filter.label, systemImage: filter.systemImage)
                        }
                    }
                }

                Section("Time") {
                    ForEach(SearchQuickFilter.timeCases, id: \.rawValue) { filter in
                        Button {
                            onApplyQuickFilter(filter)
                        } label: {
                            Label(filter.label, systemImage: filter.systemImage)
                        }
                    }
                }

                if !recentApps.isEmpty {
                    Section("Recent Apps") {
                        ForEach(recentApps, id: \.self) { appName in
                            Button {
                                onApplyRecentAppFilter(appName)
                            } label: {
                                Label(appName, systemImage: "app")
                            }
                        }
                    }
                }

                if activeFilterCount > 0 {
                    Section {
                        Button("Clear Filters", role: .destructive, action: onClearFilters)
                    }
                }

                Section("Operators") {
                    Button("type:image") {}.disabled(true)
                    Button("app:Safari") {}.disabled(true)
                    Button("fav") {}.disabled(true)
                    Button("after:2026-04-01") {}.disabled(true)
                    Button("before:2026-04-04") {}.disabled(true)
                    Button("-app:Chrome") {}.disabled(true)
                }
            } label: {
                Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(activeFilterCount > 0 ? Color.accentColor : Color.secondary)
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .help("Quick filters and supported search operators")
        }
        .padding(7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SearchFilterChipsView: View {
    let chips: [SearchFilterChip]
    let onRemove: (SearchFilterChip) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.id) { chip in
                    SearchFilterChipView(chip: chip) {
                        onRemove(chip)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

private struct SearchFilterChipView: View {
    let chip: SearchFilterChip
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: chip.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(chip.systemImage == "star.fill" ? .yellow : .secondary)

            Text(chip.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.12))
        )
    }
}
