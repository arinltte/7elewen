//
//  PowerController.swift
//  7elewen
//
//  Created by Chen Jin Shen on 08/09/2026.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

enum AppModelError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        }
    }
}

/// Owns the mechanisms that keep the Mac awake:
///  - `pmset disablesleep` (passwordless via sudoers) for lid-close sleep.
///  - `pmset lowpowermode` (optional) to save battery while the lid is shut.
///  - `IOPMAssertion` objects for idle + display sleep (released automatically on exit).
@MainActor
final class PowerController {
    private var idleAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    // MARK: Lid-close sleep

    func enableSleepDisabled() async throws {
        guard await Sudoers.ensureInstalled() else {
            throw AppModelError.commandFailed("Could not set up passwordless sleep control.")
        }
        guard await Sudoers.pmsetDisableSleep(true) else {
            throw AppModelError.commandFailed("The lid-close override could not be applied.")
        }
    }

    func disableSleepDisabled() async throws {
        if Sudoers.isConfigured() {
            _ = await Sudoers.pmsetDisableSleep(false)
        } else if Sudoers.sleepDisabled() {
            try await PrivilegedExec.runShellScript("/usr/bin/pmset disablesleep 0")
        }
    }

    /// Reads `pmset -g` and reports whether lid sleep is currently disabled.
    nonisolated static func isDisableSleepFlagSet() -> Bool {
        Sudoers.sleepDisabled()
    }

    // MARK: Low Power Mode

    /// Enables/disables Low Power Mode (passwordless). Returns true on success.
    func setLowPowerMode(_ enable: Bool) async -> Bool {
        guard await Sudoers.ensureInstalled() else { return false }
        return await Sudoers.pmsetLowPowerMode(enable)
    }

    /// Synchronous, passwordless restores used at quit.
    func restoreSleepSync() {
        _ = Sudoers.pmsetDisableSleepSync(false)
    }

    func restoreLowPowerModeSync() {
        _ = Sudoers.pmsetLowPowerModeSync(false)
    }

    // MARK: Idle + display sleep (the "never turn display off" equivalent)

    func startAwakeAssertions() {
        let reason = "7elewen stays awake with the lid closed" as CFString

        if idleAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &idleAssertion
            )
        }

        if displayAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &displayAssertion
            )
        }
    }

    func stopAwakeAssertions() {
        if idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = 0
        }
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }
}