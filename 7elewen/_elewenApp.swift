//
//  _elewenApp.swift
//  7elewen
//
//  Created by Chen Jin Shen on 08/09/2026.
//

import AppKit
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
        let controller = MenuBarController()
        controller.start()
        self.controller = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}