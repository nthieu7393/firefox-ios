// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Shared
@_exported import MozillaAppServices
import Logger

public class RustRemoteTabs {
    let databasePath: String

    let queue: DispatchQueue
    var storage: TabsStorage?

    private(set) var isOpen = false

    private var didAttemptToMoveToBackup = false
    private let logger: Logger

    public init(databasePath: String,
                logger: Logger = DefaultLogger.shared) {
        self.databasePath = databasePath
        self.logger = logger

        queue = DispatchQueue(label: "RustRemoteTabs queue: \(databasePath)", attributes: [])
    }

    private func open() -> NSError? {
        storage = TabsStorage(databasePath: databasePath)
        isOpen = true
        return nil
    }

    private func close() -> NSError? {
        storage = nil
        isOpen = false
        return nil
    }

    public func reopenIfClosed() -> NSError? {
        var error: NSError?

        queue.sync {
            guard !isOpen else { return }

            error = open()
        }

        return error
    }

    public func forceClose() -> NSError? {
        var error: NSError?

        queue.sync {
            guard isOpen else { return }

            error = close()
        }

        return error
    }

    public func sync(unlockInfo: SyncUnlockInfo) -> Success {
        let deferred = Success()

        queue.async {
            guard self.isOpen else {
                let error = TabsApiError.UnexpectedTabsError(reason: "Database is closed")
                deferred.fill(Maybe(failure: error as MaybeErrorType))
                return
            }

            do {
                try _ = self.storage?.sync(unlockInfo: unlockInfo)
                deferred.fill(Maybe(success: ()))
            } catch let err as NSError {
                if let tabsError = err as? TabsApiError {
                    self.logger.log("Tabs error when syncing Tabs database",
                                    level: .warning,
                                    category: .tabs,
                                    description: tabsError.localizedDescription)
                } else {
                    self.logger.log("Unknown error when opening Rust Tabs database",
                                    level: .warning,
                                    category: .tabs,
                                    description: err.localizedDescription)
                }

                deferred.fill(Maybe(failure: err))
            }
        }

        return deferred
    }

    public func resetSync() -> Success {
        let deferred = Success()

        queue.async {
            guard self.isOpen else {
                let error = TabsApiError.UnexpectedTabsError(reason: "Database is closed")
                deferred.fill(Maybe(failure: error as MaybeErrorType))
                return
            }

            do {
                try self.storage?.reset()
                deferred.fill(Maybe(success: ()))
            } catch let err as NSError {
                deferred.fill(Maybe(failure: err))
            }
        }

        return deferred
    }

    public func setLocalTabs(localTabs: [RemoteTab]) -> Deferred<Maybe<Int>> {
        let deferred = Deferred<Maybe<Int>>()

        queue.async {
            let tabs = localTabs.map { $0.toRemoteTabRecord() }

            if let storage = self.storage {
                storage.setLocalTabs(remoteTabs: tabs)
                deferred.fill(Maybe(success: tabs.count))
            } else {
                let error = TabsApiError.UnexpectedTabsError(reason: "Unknown error when setting local Rust Tabs")
                deferred.fill(Maybe(failure: error as MaybeErrorType))
            }
        }

        return deferred
    }

    public func getAll() -> Deferred<Maybe<[ClientRemoteTabs]>> {
        // Note: this call will get all of the client and tabs data from
        // the application storage tabs store without filter against the
        // BrowserDB client records.
        let deferred = Deferred<Maybe<[ClientRemoteTabs]>>()

        queue.async {
            guard self.isOpen else {
                let error = TabsApiError.UnexpectedTabsError(reason: "Database is closed")
                deferred.fill(Maybe(failure: error as MaybeErrorType))
                return
            }

            if let storage = self.storage {
                let records = storage.getAll()
                deferred.fill(Maybe(success: records))
            } else {
                deferred.fill(Maybe(failure: TabsApiError.UnexpectedTabsError(reason: "Unknown error when getting all Rust Tabs") as MaybeErrorType))
            }
        }

        return deferred
    }
}

public extension RemoteTabRecord {
    func toRemoteTab(client: RemoteClient) -> RemoteTab? {
        guard let url = Foundation.URL(string: self.urlHistory[0]) else { return nil }
        let history = self.urlHistory[1...].map { url in Foundation.URL(string: url) }.compactMap { $0 }
        let icon = self.icon != nil ? Foundation.URL(fileURLWithPath: self.icon ?? "") : nil

        return RemoteTab(clientGUID: client.guid, URL: url, title: self.title, history: history, lastUsed: Timestamp(self.lastUsed), icon: icon)
    }
}

public extension ClientRemoteTabs {
    func toClientAndTabs(client: RemoteClient) -> ClientAndTabs {
        return ClientAndTabs(client: client, tabs: self.remoteTabs.map { $0.toRemoteTab(client: client)}.compactMap { $0 })
    }
}
