import SwiftUI

struct LogSidebarView: View {
    @ObservedObject var store = LogStore.shared

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .frame(width: 320)
        .background(Color.black.opacity(0.05))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Logs")
                .font(.system(size: 12, weight: .semibold))
            Text("\(store.entries.count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.15))
                )
            Spacer()
            Button {
                store.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(store.entries.isEmpty)
            .help("Effacer les logs")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("Les actions et les requêtes ClickUp s'afficheront ici.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.entries) { entry in
                            row(for: entry)
                                .id(entry.id)
                            Divider().opacity(0.15)
                        }
                        Color.clear.frame(height: 1).id("__bottom__")
                    }
                }
                .onChange(of: store.entries.count) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func row(for entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.formatter.string(from: entry.timestamp))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)

            Image(systemName: entry.level.symbol)
                .font(.system(size: 9))
                .foregroundStyle(entry.level.color)
                .frame(width: 12, alignment: .center)
                .padding(.top, 1)

            Text(entry.message)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
