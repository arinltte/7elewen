//
//  MenuBarController.swift
//  7elewen
//
//  Owns the menu-bar status item (infinity symbol) + the floating Liquid Glass
//  panel it toggles. Drives a single-surface open/close animation and
//  outside-click dismissal. The panel's presentation state is exposed to the
//  SwiftUI view so the orange activation animation stops whenever the panel is
//  hidden (no idle resource use).
//

import AppKit
import SwiftUI

/// Observable bridge between the AppKit panel host and the SwiftUI surface.
@MainActor
@Observable
final class MenuBarPresenter {
    var isPresented = false

    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let presenter = MenuBarPresenter()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    private let panelSize = NSSize(width: 360, height: 360)

    func start() {
        setupStatusItem()
        setupPanel()
        observeModel()
        refreshStatusItem()
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            present()
        }
    }

    private func observeModel() {
        withObservationTracking {
            _ = AppModel.shared.isEnabled
            _ = AppModel.shared.isBusy
            _ = AppModel.shared.menuBarIconInactive
            _ = AppModel.shared.menuBarIconActive
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshStatusItem()
                self?.observeModel()
            }
        }
    }

    /// User-selected symbol (defaults to the ∞ app logo): thin/neutral when
    /// off, bold/orange when active. Falls back to ∞ for unknown symbols.
    private func refreshStatusItem() {
        let model = AppModel.shared
        let symbol = model.isEnabled ? model.menuBarIconActive : model.menuBarIconInactive
        let weight: NSFont.Weight = model.isEnabled ? .bold : .regular
        let image = (NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "7elewen"
        ) ?? NSImage(systemSymbolName: "infinity", accessibilityDescription: "7elewen"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: weight))
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = model.isEnabled ? .systemOrange : nil
    }

    // MARK: Panel

    private func setupPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(
            rootView: ContentView()
                .environment(AppModel.shared)
                .environment(presenter)
        )
        self.panel = panel
    }

    private func present() {
        guard let panel else { return }
        positionPanel()
        installOutsideClickMonitor()
        panel.makeKeyAndOrderFront(nil)

        presenter.isPresented = false
        if presenter.reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) { presenter.isPresented = true }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { presenter.isPresented = true }
        }
    }

    private func dismiss() {
        guard presenter.isPresented else {
            panel?.orderOut(nil)
            removeOutsideClickMonitor()
            return
        }
        // isPresented drives both the fade/scale-out and — critically — removes
        // the orange activation ring, stopping its animation immediately.
        withAnimation(.easeOut(duration: presenter.reduceMotion ? 0.12 : 0.18)) {
            presenter.isPresented = false
        }
        let delay = presenter.reduceMotion ? 0.12 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.panel?.orderOut(nil)
            self?.removeOutsideClickMonitor()
        }
    }

    private func positionPanel() {
        guard let panel, let button = statusItem?.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        // The status item lives in the menu bar's own window, so convert its
        // bounds explicitly to screen coordinates before positioning.
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame

        var frame = panel.frame
        frame.size = panelSize

        // Center horizontally under the status item, clamped to the screen.
        frame.origin.x = min(
            max(buttonRect.midX - panelSize.width / 2, visible.minX + 8),
            visible.maxX - panelSize.width - 8
        )

        // Anchor the panel just below the menu bar.
        frame.origin.y = buttonRect.minY - panelSize.height - 8

        panel.setFrame(frame, display: false)
    }

    // MARK: Outside-click dismissal

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}