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

    /// Lid angle (degrees) at or below which the display dims. Range 0…30°.
    var dimAngle: Double = min(max(load("dimAngle", fallback: 4.0), 0), 30) {
        didSet { UserDefaults.standard.set(dimAngle, forKey: "dimAngle") }
    }

    /// Lid angle (degrees) at or above which the display brightens again.
    /// Range 1…30°, kept above `dimAngle` so the two can never coincide.
    var brightenAngle: Double = min(max(load("brightenAngle", fallback: 20.0), 1), 30) {
        didSet { UserDefaults.standard.set(brightenAngle, forKey: "brightenAngle") }
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
    /// Persisted (not just in-memory) so a crashed run — which never reaches
    /// `shutdown()` — can reconcile Low Power Mode at next launch: true iff
    /// *this* app enabled it for a closed lid.
    private var didEnableLowPowerMode = UserDefaults.standard.bool(forKey: "didEnableLowPowerMode") {
        didSet { UserDefaults.standard.set(didEnableLowPowerMode, forKey: "didEnableLowPowerMode") }
    }

    var detailText: String {
        if let error = lastError { return error }
        return isEnabled ? "You're good to go 24/7" : "Macbook will enter sleep mode if lid close"
    }

    /// The open threshold, with a guaranteed minimum hysteresis above `dimAngle`.
    private var effectiveOpenThreshold: Double {
        max(brightenAngle, dimAngle + 5)
    }

    init() {
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
            wasLidClosed = sensor.angle <= dimAngle
            lidClosed = wasLidClosed
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
        if !wasLidClosed && angle <= dimAngle {
            wasLidClosed = true
            lidClosed = true
            brightness.set(Float(dimBrightness) / 100.0)
            Self.logger.info("Lid closed (angle \(angle, format: .fixed(precision: 1))) — dimming to \(self.dimBrightness, format: .fixed(precision: 0))%")
            if lowPowerModeWhenClosed {
                Task {
                    if await power.setLowPowerMode(true) {
                        didEnableLowPowerMode = true
                    }
                }
            }
        } else if wasLidClosed && angle >= effectiveOpenThreshold {
            wasLidClosed = false
            lidClosed = false
            brightness.set(savedBrightness)
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