//
//  SettingsStore.swift
//  GlisseKit
//
//  The one place that touches UserDefaults.
//
//  Everything else takes an `AppSettings` snapshot. Consumers that run off the
//  main thread (the gesture actor, the DDC queue) read `snapshot`, which is
//  lock-protected, rather than reaching back into UserDefaults on a hot path.
//

import Foundation

public final class SettingsStore: @unchecked Sendable {

    public static let shared = SettingsStore()

    private static let storageKey = "settings.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var _settings: AppSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hadOwnData = defaults.data(forKey: Self.storageKey) != nil
        let loaded = Self.load(from: defaults)
        self._settings = loaded
        Log.diagnosticsEnabled = loaded.diagnosticLogging
        // Take ownership of migrated values straight away, so the legacy domain is
        // consulted exactly once.
        if !hadOwnData, loaded != .default {
            persist(loaded)
        }
    }

    // MARK: Read

    /// Thread-safe snapshot. Cheap: a struct copy under a lock.
    public var snapshot: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return _settings
    }

    // MARK: Write

    /// Applies a mutation, persists it and notifies observers.
    /// - Returns: the settings after mutation and validation.
    @discardableResult
    public func update(_ mutate: (inout AppSettings) -> Void) -> AppSettings {
        lock.lock()
        var next = _settings
        mutate(&next)
        next = next.validated()
        let changed = next != _settings
        if changed { _settings = next }
        lock.unlock()

        guard changed else { return next }

        Log.diagnosticsEnabled = next.diagnosticLogging
        persist(next)
        return next
    }

    public func resetToDefaults() {
        update { $0 = .default }
    }

    // MARK: Persistence

    private func persist(_ settings: AppSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            Log.settings.error("failed to encode settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey) ?? migratedLegacyData() else {
            return .default
        }
        do {
            // Decoding into a struct that has gained fields since the data was
            // written would throw, so decode leniently: fall back to defaults
            // for anything missing by round-tripping through a dictionary.
            return try JSONDecoder().decode(AppSettings.self, from: data).validated()
        } catch {
            Log.settings.warning("""
                stored settings could not be decoded (\(error.localizedDescription, privacy: .public)); \
                falling back to defaults
                """)
            return Self.lenientDecode(data) ?? .default
        }
    }

    /// Reads preferences left behind by the app's previous bundle identifier.
    ///
    /// Renaming the app changes the identifier, and therefore the `UserDefaults`
    /// domain, which would silently reset every preference. This picks the old
    /// domain up once; from then on the new domain has data of its own and this is
    /// never consulted again.
    private static func migratedLegacyData() -> Data? {
        guard let legacy = UserDefaults(suiteName: Branding.legacyDefaultsDomain),
              let data = legacy.data(forKey: storageKey) else {
            return nil
        }
        Log.settings.info("migrating settings from \(Branding.legacyDefaultsDomain, privacy: .public)")
        return data
    }

    /// Merges stored values over the defaults key by key. Lets a settings file
    /// written by an older build survive adding a new preference.
    private static func lenientDecode(_ data: Data) -> AppSettings? {
        guard
            let storedObject = try? JSONSerialization.jsonObject(with: data),
            var stored = storedObject as? [String: Any],
            let defaultData = try? JSONEncoder().encode(AppSettings.default),
            let defaultObject = try? JSONSerialization.jsonObject(with: defaultData),
            let defaultDict = defaultObject as? [String: Any]
        else { return nil }

        for (key, value) in defaultDict where stored[key] == nil {
            stored[key] = value
        }
        guard
            let merged = try? JSONSerialization.data(withJSONObject: stored),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: merged)
        else { return nil }
        return settings.validated()
    }
}
