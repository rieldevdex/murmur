import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Files parked on the notch. These are references to the originals, nothing is copied or moved.
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [URL] = []
    private let key = "shelfItems"

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        var changed = false
        for raw in urls where raw.isFileURL {
            // Finder often hands over a file *reference* (file:///.file/id=…), which has no real
            // path: turn it into the actual location, or the shelf thinks the file is missing
            let url = ((raw as NSURL).filePathURL ?? raw).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path), !items.contains(url) else { continue }
            items.append(url)
            changed = true
        }
        guard changed else { return }
        save()
        // Show the files, not the clipboard, so you see what you just dropped
        if UserDefaults.standard.string(forKey: "shelfMode") != "files" {
            UserDefaults.standard.set("files", forKey: "shelfMode")
        }
    }

    /// The files in a drag, read straight from the drag pasteboard
    static func urls(on board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self],
                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Drops anything that was moved or deleted since it was shelved
    func prune() {
        let kept = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if kept.count != items.count { items = kept; save() }
    }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }

    /// Reads file URLs out of a drop
    static func load(_ providers: [NSItemProvider]) {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                guard let found = url else { return }
                DispatchQueue.main.async { ShelfStore.shared.add([found]) }
            }
        }
    }
}

struct ShelfView: View {
    @ObservedObject var store = ShelfStore.shared
    let accent: Color
    let targeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            if store.items.isEmpty {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(targeted ? accent : Color.white.opacity(0.2),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(targeted ? 0.12 : 0)))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 22, weight: .medium))
                            Text("Drop files here to keep them handy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(targeted ? accent : Color.white.opacity(0.5))
                    )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.items, id: \.self) { url in
                            ShelfTile(url: url, accent: accent)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(accent, lineWidth: targeted ? 1.5 : 0)
                )

                HStack(spacing: 14) {
                    Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s") · drag out to use")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                    shelfButton("AirDrop", "dot.radiowaves.left.and.right") {
                        store.airDrop(store.items)
                    }
                    shelfButton("Clear", "trash") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.clear() }
                    }
                }
            }
        }
        .onAppear { store.prune() }
    }

    private func shelfButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
    }
}

struct ShelfTile: View {
    let url: URL
    let accent: Color
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(url.lastPathComponent)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 64)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovering ? 0.1 : 0.04)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { ShelfStore.shared.remove(url) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.8), Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .help("Remove from the shelf (the file itself stays put)")
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
    }
}
