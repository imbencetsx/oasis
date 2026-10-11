import SwiftUI

struct FindBar: View {
    @Bindable var tab: BrowserTab
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            Text(tab.findResult).font(.caption).foregroundStyle(.secondary)
            TextField("Find on page", text: $tab.findText)
                .textFieldStyle(.roundedBorder).frame(width: 240).focused($focused)
                .onSubmit { tab.find() }
                .onChange(of: tab.findText) { tab.find() }
                .onExitCommand { isPresented = false }
            Button("Previous Match", systemImage: "chevron.up") { tab.find(backwards: true) }.labelStyle(.iconOnly)
            Button("Next Match", systemImage: "chevron.down") { tab.find() }.labelStyle(.iconOnly)
            Button("Done") { isPresented = false }
        }.padding(.horizontal, 14).padding(.vertical, 8)
            .onAppear { focused = true }
    }
}

struct DownloadsPanel: View {
    @Bindable var downloads: BrowserDownloads
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }.buttonStyle(OasisButtonStyle()).font(.caption).disabled(!downloads.items.contains { $0.isFinished })
            }.padding(18)
            Divider()
            if downloads.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                    Text("Your downloads appear here").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 45)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(downloads.items) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.failed ? "exclamationmark.doc" : "doc").font(.title2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    if !item.isFinished { ProgressView(value: item.fraction).controlSize(.small) }
                                    Text(item.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                if !item.isFinished {
                                    Button("Cancel Download", systemImage: "xmark.circle") { downloads.cancel(item) }.labelStyle(.iconOnly).buttonStyle(OasisButtonStyle())
                                } else if let url = item.destination, !item.failed, item.status == "Complete" {
                                    Button("Show in Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                        .labelStyle(.iconOnly).buttonStyle(OasisButtonStyle()).help("Show in Finder")
                                }
                            }.padding(15)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 350)
            }
            HStack {
                Text("Files are saved only to a location you choose.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }.padding(14)
        }.frame(width: 380)
    }
}

struct ReaderView: View {
    let article: ReaderContent
    let tab: BrowserTab
    @State private var fontSize = 19.0
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: .textBackgroundColor).opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(tab.url?.displayHost ?? "").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(article.title).font(.system(size: 35, weight: .semibold, design: .serif))
                    Divider()
                    Text(article.text).font(.system(size: fontSize, design: .serif)).lineSpacing(9).textSelection(.enabled)
                }.frame(maxWidth: 680).padding(.horizontal, 50).padding(.vertical, 70).frame(maxWidth: .infinity)
            }
            HStack(spacing: 14) {
                Button("Smaller Text", systemImage: "textformat.size.smaller") { fontSize = max(14, fontSize - 1) }.labelStyle(.iconOnly)
                Button("Larger Text", systemImage: "textformat.size.larger") { fontSize = min(30, fontSize + 1) }.labelStyle(.iconOnly)
                Divider().frame(height: 15)
                Button("Close Reader", systemImage: "xmark") { tab.showsReader = false }.labelStyle(.iconOnly)
            }.buttonStyle(OasisButtonStyle()).padding(13).glassEffect(.regular, in: .capsule).padding(18)
        }
    }
}

