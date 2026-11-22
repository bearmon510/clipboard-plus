import Foundation
import Security

@MainActor
protocol PCSyncKeyStore {
    func read() throws -> Data?
    func write(_ key: Data) throws
    func delete() throws
}

/// A single local pairing secret. Never included in history export or backup manifests.
@MainActor
final class PCSyncKeychain: PCSyncKeyStore {
    private let service: String
    init(service: String = "clipboardplus.pc-sync.v1") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "pairing-key",
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw Failure() }
        return data
    }
    func write(_ key: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let request = query.merging(attributes) { _, new in new }
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw Failure() }
        } else if status != errSecSuccess { throw Failure() }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure() }
    }
    private struct Failure: Error {}
}

@MainActor
final class PCSyncSettings {
    private let defaults: UserDefaults
    private let prefix = "pcSync.v1."
    init(defaults: UserDefaults) { self.defaults = defaults }
    var pcName: String? {
        guard !deletionPending, defaults.string(forKey: prefix + "pcId") != nil else { return nil }
        return defaults.string(forKey: prefix + "pcName")
    }
    var padId: UUID {
        if let text = defaults.string(forKey: prefix + "padId"), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: prefix + "padId")
        return id
    }
    var peripheralId: UUID? {
        get { defaults.string(forKey: prefix + "peripheralId").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: prefix + "peripheralId") }
    }
    var copiesReceivedToPasteboard: Bool {
        get { defaults.object(forKey: prefix + "copiesReceivedToPasteboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "copiesReceivedToPasteboard") }
    }
    var usesWifiForLargeItems: Bool {
        get { defaults.object(forKey: prefix + "usesWifiForLargeItems") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "usesWifiForLargeItems") }
    }
    var wifiThreshold: PCSyncWifiThreshold {
        get {
            guard let raw = defaults.object(forKey: prefix + "wifiThresholdBytes") as? Int,
                  let value = PCSyncWifiThreshold(rawValue: raw) else {
                return .defaultValue
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: prefix + "wifiThresholdBytes") }
    }
    var requiresPeerUpdate: Bool {
        get { defaults.bool(forKey: prefix + "requiresPeerUpdate") }
        set { defaults.set(newValue, forKey: prefix + "requiresPeerUpdate") }
    }
    var requiresRepair: Bool {
        get { defaults.bool(forKey: prefix + "requiresRepair") }
        set { defaults.set(newValue, forKey: prefix + "requiresRepair") }
    }
    // A deletion tombstone prevents loading a stale secret if Keychain is temporarily locked.
    var deletionPending: Bool {
        get { defaults.bool(forKey: prefix + "deletionPending") }
        set { defaults.set(newValue, forKey: prefix + "deletionPending") }
    }
    func load(key: Data) throws -> SyncPairing? {
        guard !deletionPending,
              let value = defaults.string(forKey: prefix + "pcId"), let id = UUID(uuidString: value),
              let name = defaults.string(forKey: prefix + "pcName") else { return nil }
        return try SyncPairing(pcId: id, key: key, name: name)
    }
    func save(_ pairing: SyncPairing) {
        defaults.set(pairing.pcId.uuidString, forKey: prefix + "pcId")
        defaults.set(pairing.name, forKey: prefix + "pcName")
        deletionPending = false
        peripheralId = nil
    }
    func clearPairing() {
        defaults.removeObject(forKey: prefix + "pcId")
        defaults.removeObject(forKey: prefix + "pcName")
        defaults.removeObject(forKey: prefix + "requiresPeerUpdate")
        defaults.removeObject(forKey: prefix + "requiresRepair")
        peripheralId = nil
    }
}
