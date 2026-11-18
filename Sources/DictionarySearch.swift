import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Looking up any word from the notch
//
// Shelf › Dictionary, or ⌃⌥D from anywhere. Results come from the dictionaries turned on in the
// Dictionary app, as you type. While the search box is open the island takes the keyboard; Esc,
// clicking elsewhere or closing the island gives it straight back to the app you were in.

@MainActor
final class DictionarySearch: ObservableObject {
    static let shared = DictionarySearch()

    @Published var query = ""
    @Published private(set) var result: WordDefinition?
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "dictRecent") ?? []
    /// Bumped to put the cursor in the search box (shortcut, menu)
    @Published var focusRequest = 0
    /// Set by the shortcut when the box isn't on screen yet: focus it as soon as it appears
    var focusOnAppear = false

    private var pending: Task<Void, Never>?

    /// Looks up what's typed, after a short pause so it doesn't search on every key
    func update() {
        pending?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            result = nil
            suggestions = []
            return
        }
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            let found = ClipboardStore.define(q)
            withAnimation(.easeOut(duration: 0.15)) {
                result = found
                suggestions = Self.suggest(q, found: found != nil)
            }
        }
    }

    func choose(_ word: String) {
        query = word
        update()
    }

    /// The word you ended up reading goes to the top of Recent
    func rememberCurrent() {
        guard let word = result?.word, !word.isEmpty else { return }
        var list = recent.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
        list.insert(word, at: 0)
        recent = Array(list.prefix(8))
        UserDefaults.standard.set(recent, forKey: "dictRecent")
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: "dictRecent")
    }

    /// Words that start with what's typed, and spelling fixes when nothing was found
    private static func suggest(_ q: String, found: Bool) -> [String] {
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (q as NSString).length)
        var out: [String] = []
        if !q.contains(" ") {
            out += checker.completions(forPartialWordRange: range, in: q, language: nil,
                                       inSpellDocumentWithTag: 0) ?? []
        }
        if !found {
            out = (checker.guesses(forWordRange: range, in: q, language: nil, inSpellDocumentWithTag: 0) ?? []) + out
        }
        var seen = Set<String>()
        return out.filter { word in
            let key = word.lowercased()
            guard key != q.lowercased(), !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        .prefix(found ? 4 : 6)
        .map { $0 }
    }
}

struct DictionarySearchView: View {
    @ObservedObject private var search = DictionarySearch.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: search.query) { _ in search.update() }
        .onChange(of: search.focusRequest) { _ in
            search.focusOnAppear = false
            startTyping()
        }
        .onAppear {
            // Opened with the shortcut: straight into the box. Opened by hovering: only when you
            // click it, so pointing at the notch never steals the keyboard
            if search.focusOnAppear {
                search.focusOnAppear = false
                startTyping()
            }
        }
        .onDisappear {
            search.rememberCurrent()
            NotchController.shared.endTyping()
        }
    }

    // MARK: The search box

    private var field: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IslandType.tertiary)
            TextField("Look up a word", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .focused($focused)
                .onSubmit {
                    if search.result == nil, let first = search.suggestions.first { search.choose(first) }
                    search.rememberCurrent()
                }
                .onExitCommand { NotchController.shared.collapse() }
            if !search.query.isEmpty {
                roundButton("xmark", help: "Clear") {
                    search.query = ""
                    startTyping()
                }
            }
            if let word = search.result?.word {
                roundButton("arrow.up.forward.app", help: "Open in Dictionary") {
                    search.rememberCurrent()
                    NotchController.shared.collapse()
                    DictionaryApp.open(word)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(focused ? 0.14 : 0.09)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.18 : 0), lineWidth: 1))
        .contentShape(Capsule())
        .simultaneousGesture(TapGesture().onEnded { startTyping() })
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    // MARK: Below the box

    @ViewBuilder
    private var content: some View {
        let q = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = search.result {
            let entry = DictEntry.parse(d)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    DictHeadline(entry: entry, size: 16, showFirstPOS: false)
                    ForEach(entry.sections.indices, id: \.self) { i in
                        DictSectionView(section: entry.sections[i], showPronunciation: i > 0)
                    }
                    if !search.suggestions.isEmpty {
                        chips(search.suggestions, label: "Also")
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 4)
            }
            .id(d.word)
            .transition(.opacity)
        } else if !q.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No entry for \u{201C}\(q)\u{201D}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IslandType.secondary)
                if !search.suggestions.isEmpty {
                    chips(search.suggestions, label: "Did you mean")
                }
            }
            .padding(.horizontal, 4)
            .transition(.opacity)
        } else if !search.recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    chips(search.recent, label: "Recent")
                    Spacer(minLength: 0)
                    Button("Clear") { search.clearRecent() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IslandType.tertiary)
                }
                hint
            }
            .padding(.horizontal, 4)
        } else {
            hint.padding(.horizontal, 4)
        }
    }

    private var hint: some View {
        Text(DictionaryHotKey.enabled
             ? "Uses the dictionaries turned on in the Dictionary app. \u{2303}\u{2325}D opens this from anywhere."
             : "Uses the dictionaries turned on in the Dictionary app.")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(IslandType.tertiary)
    }

    private func chips(_ words: [String], label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(IslandType.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(words, id: \.self) { word in
                        Button {
                            NotchController.haptic(.generic)
                            search.choose(word)
                        } label: {
                            Text(word)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            NotchController.haptic(.generic)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    private func startTyping() {
        NotchController.shared.beginTyping()
        DispatchQueue.main.async { focused = true }
    }
}

// MARK: - ⌃⌥D from anywhere

/// A system-wide shortcut through the classic hot-key API, which needs no extra permission
enum DictionaryHotKey {
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "dictHotKey") as? Bool ?? true
    }

    static func setEnabled(_ on: Bool) {
        if on { register() } else { unregister() }
    }

    private static func register() {
        guard ref == nil else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in NotchController.shared.openDictionary() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x4D52_4D52), id: 1)   // "MRMR"
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    private static func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil
    }
}
