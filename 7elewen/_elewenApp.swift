//
//  _elewenApp.swift
//  7elewen
//
//  Created by Chen Jin Shen on 08/09/2026.
//

import AppKit
import ServiceManagement
import SwiftUI

@main
struct _elewenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app window of its own.
        NSApp.setActivationPolicy(.accessory)
        registerLoginItemIfNeeded()
        let controller = MenuBarController()
        controller.start()
        self.controller = controller
    }

    /// Relaunch at login so the crash-safety reconciliation in AppModel.init
    /// runs on every boot, even if the user never reopens the app.
    ///
    /// Registration happens on the very first launch only. Afterwards, a login
    /// item that has disappeared means the user turned the feature off in
    /// System Settings — respect that and never silently re-register behind
    /// their back. They can always re-enable it there themselves.
    private func registerLoginItemIfNeeded() {
        let key = "didRegisterLoginItem"
        switch SMAppService.mainApp.status {
        case .enabled:
            // Already running at login; nothing to do. Record that registration
            // was handled so a later removal is recognized as user intent.
            UserDefaults.standard.set(true, forKey: key)
        case .notRegistered:
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: key)
            } catch {
                // Leave the flag unset so the next launch retries registration.
            }
        default:
            // .requiresApproval / .notFound: pending user approval or an
            // unusual state (e.g. the app was moved) — leave it alone.
            break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}