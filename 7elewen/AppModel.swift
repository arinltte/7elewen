//
//  AppModel.swift
//  7elewen
//
//  Created by Chen Jin Shen on 08/09/2026.
//

import Foundation
import os

/// Central state for the menu-bar app. Orchestrates the sleep-blocking power
/// settings, the lid-sensor driven brightness, and (optional) Low Power Mode.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    nonisolated static let logger = Logger(subsystem: "arinltte.7elewen", category: "AutoDim")

    // MARK: Published state

    private(set) var isEnabled = false
    private(set) var isBusy = false
    private(set) var lastError: String?
    private(set) var lidClosed = false

    // MARK: User settings (persisted + observable)

    /// Single lid-angle threshold (degrees): the display dims once the lid
    /// closes past this angle and brightens again once it opens past it — with
    /// 1° of hidden hysteresis on each side (see `closeThreshold`/
    /// `openThreshold`) so the lid hovering right at the setting can't
    /// flicker the display. Range 1…100°.
    ///
    /// Stored under its own key: the v0.3.x `dimAngle`/`brightenAngle` pair had
    /// different semantics, so old values are reset rather than carried over.
    var dimThreshold: Double = min(max(load("dimThreshold", fallback: 20.0), 1), 100) {
        didSet { UserDefaults.standard.set(dimThreshold, forKey: "dimThreshold") }
    }

    /// Brightness level (0…50%) the display dims to while the lid is shut.
    var dimBrightness: Double = min(max(load("dimBrightness", fallback: 50.0), 0), 50) {
        didSet { UserDefaults.standard.set(dimBrightness, forKey: "dimBrightness") }
    }

    /// Enable Low Power Mode while the lid is shut.
    var lowPowerModeWhenClosed: Bool = UserDefaults.standard.bool(forKey: "lowPowerModeWhenClosed") {
        didSet { UserDefaults.standard.set(lowPowerModeWhenClosed, forKey: "lowPowerModeWhenClosed") }
    }

    /// SF Symbol shown in the menu bar while the app is deactivated.
    /// Defaults to "infinity" — the app logo.
    var menuBarIconInactive: String = UserDefaults.standard.string(forKey: "menuBarIconInactive") ?? "infinity" {
        didSet { UserDefaults.standard.set(menuBarIconInactive, forKey: "menuBarIconInactive") }
    }

    /// SF Symbol shown in the menu bar while the app is activated.
    /// Defaults to "infinity" — the app logo.
    var menuBarIconActive: String = UserDefaults.standard.string(forKey: "menuBarIconActive") ?? "infinity" {
        didSet { UserDefaults.standard.set(menuBarIconActive, forKey: "menuBarIconActive") }
    }

    /// Effect animated around the main activate button while enabled:
    /// "pulse" (expanding glow, the original), "circulate" (orbiting glow),
    /// or "off".
    var buttonEffect: String = UserDefaults.standard.string(forKey: "buttonEffect") ?? "pulse" {
        didSet { UserDefaults.standard.set(buttonEffect, forKey: "buttonEffect") }
    }

    // MARK: Dependencies

    let sensor = LidAngleSensor()
    private let power = PowerController()
    private let brightness = BrightnessController()

    private var savedBrightness: Float = 0.6
    private var wasLidClosed = false
    /// macOS ramps display brightness over roughly a second, so a reading taken
    /// mid-ramp is an intermediate value (e.g. 40% while the display is on its
    /// way to 50%). Capture is paused until the display settles — otherwise the
    /// app would remember the intermediate value and restore *that* on the next
    /// lid cycle instead of the level the user chose.
    private var brightnessSettleUntil: Date?

    /// Persisted (not just in-memory) so a crashed run — which never reaches
    /// `shutdown()` — can reconcile Low Power Mode at next launch: true iff
    /// *this* app enabled it for a closed lid.
    private var didEnableLowPowerMode = UserDefaults.standard.bool(forKey: "didEnableLowPowerMode") {
        didSet { UserDefaults.standard.set(didEnableLowPowerMode, forKey: "didEnableLowPowerMode") }
    }

    /// How long to wait for the display to finish a brightness transition.
    private static let brightnessSettleInterval: TimeInterval = 2.5

    var detailText: String {
        if let error = lastError { return error }
        guard isEnabled else { return "Macbook will enter sleep mode if lid close" }
        return lidClosed ? "Lid closed — display dimmed" : "You're good to go 24/7"
    }

    /// Whether the display has finished a brightness transition, so its current
    /// reading can be trusted as the user's chosen level.
    private var isBrightnessSettled: Bool {
        guard let deadline = brightnessSettleUntil else { return true }
        return Date.now >= deadline
    }

    /// Hidden hysteresis (degrees) around `dimThreshold`.
    private let hysteresis = 1.0

    /// The display dims once the lid closes past this angle.
    private var closeThreshold: Double { dimThreshold - hysteresis }

    /// The display brightens again once the lid opens past this angle.
    private var openThreshold: Double { dimThreshold + hysteresis }

    init() {
        // v0.4.0 replaced the two-angle settings (`dimAngle` + `brightenAngle`)
        // with a single threshold whose meaning differs, so existing installs
        // reset to the new default instead of carrying over a stale value.
        if UserDefaults.standard.object(forKey: "brightenAngle") != nil {
            UserDefaults.standard.removeObject(forKey: "dimAngle")
            UserDefaults.standard.removeObject(forKey: "brightenAngle")
        }

        // Crash safety net: `disablesleep` and `lowpowermode` are persistent
        // system settings that survive force-quit, kernel panic, dead battery
        // and reboot — all paths that never reach `shutdown()`. Reconcile them
        // back to "normal sleep" here on every launch. A login item re-runs this
        // at each boot (see _elewenApp), and the app re-enables the flags only
        // while it is actually running.
        power.restoreSleepSync()
        if didEnableLowPowerMode {
            didEnableLowPowerMode = false
            power.restoreLowPowerModeSync()
        }
    }

    // MARK: User actions

    func toggle() {
        if isEnabled { disable() } else { enable() }
    }

    func enable() {
        guard !isBusy else { return }
        Task { await performEnable() }
    }

    func disable() {
        guard !isBusy else { return }
        Task { await performDisable() }
    }

    /// Synchronous cleanup at quit: restore normal sleep before exit.
    func shutdown() {
        sensor.stop()
        power.stopAwakeAssertions()
        if isEnabled {
            brightness.set(savedBrightness)
        }
        power.restoreSleepSync()
        if didEnableLowPowerMode {
            didEnableLowPowerMode = false
            power.restoreLowPowerModeSync()
        }
    }

    // MARK: Enable / disable

    private func performEnable() async {
        // Fail fast (and loudly — `lastError` drives the panel text and the
        // menu-bar warning icon) instead of silently sitting there responding
        // to nothing if the HID sensor couldn't be located.
        guard sensor.hasDevice else {
            lastError = "Lid angle sensor not found on this Mac."
            return
        }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            try await power.enableSleepDisabled()
            power.startAwakeAssertions()

            if let current = brightness.current() {
                savedBrightness = current
            }

            sensor.onAngleChange = { [weak self] angle in
                self?.react(toAngle: angle)
            }
            wasLidClosed = sensor.angle <= closeThreshold
            lidClosed = wasLidClosed
            if wasLidClosed {
                // Enabled while the lid is already shut: dim straight away
                // instead of waiting for the next close/open cycle.
                brightness.set(Float(dimBrightness) / 100.0)
                brightnessSettleUntil = Date.now.addingTimeInterval(Self.brightnessSettleInterval)
            }
            sensor.start()

            isEnabled = true
        } catch {
            power.stopAwakeAssertions()
            lastError = Self.message(for: error)
        }
    }

    private func performDisable() async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        sensor.stop()
        sensor.onAngleChange = nil

        brightness.set(savedBrightness)
        power.stopAwakeAssertions()

        do {
            try await power.disableSleepDisabled()
        } catch {
            lastError = Self.message(for: error)
        }

        if didEnableLowPowerMode {
            didEnableLowPowerMode = false
            _ = await power.setLowPowerMode(false)
        }

        isEnabled = false
        wasLidClosed = false
        lidClosed = false
    }

    // MARK: Lid reaction

    private func react(toAngle angle: Double) {
        // Mirror the live system brightness while the lid is open, so that after
        // any dim cycle the display returns to exactly the level the user last
        // chose — not the level captured when the feature was enabled, and never
        // the dimmed level itself.
        if !wasLidClosed, let current = brightness.current(), isBrightnessSettled {
            savedBrightness = current
        }

        if !wasLidClosed && angle <= closeThreshold {
            wasLidClosed = true
            lidClosed = true
            brightness.set(Float(dimBrightness) / 100.0)
            brightnessSettleUntil = Date.now.addingTimeInterval(Self.brightnessSettleInterval)
            Self.logger.info("Lid closed (angle \(angle, format: .fixed(precision: 1))) — dimming to \(self.dimBrightness, format: .fixed(precision: 0))%")
            if lowPowerModeWhenClosed {
                Task {
                    if await power.setLowPowerMode(true) {
                        didEnableLowPowerMode = true
                    }
                }
            }
        } else if wasLidClosed && angle >= openThreshold {
            wasLidClosed = false
            lidClosed = false
            brightness.set(savedBrightness)
            brightnessSettleUntil = Date.now.addingTimeInterval(Self.brightnessSettleInterval)
            Self.logger.info("Lid opened (angle \(angle, format: .fixed(precision: 1))) — restoring brightness")
            if didEnableLowPowerMode {
                didEnableLowPowerMode = false
                Task { _ = await power.setLowPowerMode(false) }
            }
        }
    }

    private nonisolated static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private nonisolated static func load(_ key: String, fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key)
    }
}