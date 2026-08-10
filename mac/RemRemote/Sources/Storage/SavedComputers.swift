import Foundation
import Combine

/// A known computer. Non-secret metadata lives in UserDefaults; the channel key and
/// optional encryption password live in the macOS keychain, one item per computer.
struct SavedComputer: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: UInt16 = 6837

    var address: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port == 6837 ? h : "\(h):\(port)"
    }
}

final class SavedComputersStore: ObservableObject {
    private static let defaultsKey = "savedComputers"

    @Published private(set) var computers: [SavedComputer] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let list = try? JSONDecoder().decode([SavedComputer].self, from: data) {
            computers = list
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(computers) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func secrets(for computer: SavedComputer) -> KeychainStore.Secrets? {
        KeychainStore.load(for: computer.id)
    }

    /// Adds or updates a computer, writing its secrets to the keychain.
    func save(_ computer: SavedComputer, key: String, encryptionPassword: String?) throws {
        let secrets = KeychainStore.Secrets(
            key: key,
            encryptionPassword: (encryptionPassword?.isEmpty ?? true) ? nil : encryptionPassword
        )
        try KeychainStore.save(secrets, for: computer.id)
        if let index = computers.firstIndex(where: { $0.id == computer.id }) {
            computers[index] = computer
        } else {
            computers.append(computer)
        }
        persist()
    }

    func remove(_ computer: SavedComputer) {
        KeychainStore.delete(for: computer.id)
        computers.removeAll { $0.id == computer.id }
        persist()
    }
}
