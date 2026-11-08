import Foundation
import os

extension Logger {
    /// A logger named by the running bundle's identifier, so the app, its helper and each
    /// build (release or Debug) log under their own identity.
    public init(category: String) {
        self.init(subsystem: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, category: category)
    }
}
