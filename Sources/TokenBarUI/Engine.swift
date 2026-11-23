import Foundation
import LocalCore

/// Owns the store and scanner. All database work runs on one serial background
/// queue at utility QoS, so the UI thread never touches SQLite.
public final class Engine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tokenbar.engine", qos: .utility)
    private var store: UsageStore?
    private var openError: String?

    public let home: String

    private let dbPath: String

    /// Returns at once: the index opens on the engine's queue (WAL setup, schema check and a
    /// writer's lock can take seconds), ahead of the first request that needs it.
    public init(home: String = NSHomeDirectory(), dbPath: String = UsageStore.defaultPath) {
        self.home = home
        self.dbPath = dbPath
        PriceBook.useHome(home)
        queue.async { [self] in
            HarnessCatalog.load(home: home).register()
            openStore()
        }
    }

    /// Only on `queue`.
    private func openStore() {
        do {
            store = try UsageStore(path: dbPath)
            openError = nil
        } catch {
            openError = String(describing: error)
        }
    }

    /// Only on `queue`. A failed open is tried again with the next request: the lock that
    /// stopped it may be gone.
    private func requireStore() throws -> UsageStore {
        if store == nil { openStore() }
        guard let store else { throw StoreError(message: openError ?? L10n.t("Veritabanı açılamadı", "Could not open the database")) }
        return store
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func scan() async throws -> ScanResult {
        try await run { UsageScanner(store: try self.requireStore(), home: self.home).scan() }
    }

    public func book() async throws -> UsageBook {
        try await run { try self.requireStore().usageBook() }
    }
}
