import Combine
import Foundation

/// The settings and archive windows edit the same preferences instance, preventing
/// a stale window from replacing changes saved by another window.
@MainActor
enum AppPreferences {
    private static var languageObservation: AnyCancellable?
    static let store: PreferencesStore = {
        let store = PreferencesStore()
        languageObservation = bindLocalization(to: store)
        return store
    }()

    static func bindLocalization(to store: PreferencesStore) -> AnyCancellable {
        let snapshot = LanguageSnapshot(store.preferences.language)
        L10n.languageProvider = { snapshot.value }
        return store.$preferences
            .map(\.language)
            .removeDuplicates()
            .sink { snapshot.update($0) }
    }
}

// File tasks also localize messages from background threads. Capture only a locked
// language value, never the UI store or its settings file, in their provider.
private final class LanguageSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var language: AppLanguage

    init(_ language: AppLanguage) { self.language = language }
    var value: AppLanguage { lock.withLock { language } }
    func update(_ language: AppLanguage) { lock.withLock { self.language = language } }
}
