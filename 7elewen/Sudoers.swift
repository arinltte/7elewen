//
//  Sudoers.swift
//  7elewen
//
//  Created by Chen Jin Shen on 08/09/2026.
//

import Darwin
import Foundation

/// Manages a sudoers drop-in file so several `pmset` commands run without a
/// password. Installing the rule needs one admin password; after that every
/// command is fully passwordless.
nonisolated enum Sudoers {
    static let sudoersFile = "/etc/sudoers.d/7elewen"
    static let tempFile = "/tmp/7elewen-sudoers"

    // MARK: Rule

    /// NOPASSWD rule keyed by uid (bare digits can't be misread by sudoers or shell).
    static func rule(forUID uid: uid_t = getuid()) -> String {
        "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0, /usr/bin/pmset lowpowermode 1, /usr/bin/pmset lowpowermode 0\n"
    }

    // MARK: State

    /// Whether the passwordless rule is installed *and* covers low power mode.
    static func isConfigured() -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sudoersFile, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        // The installed file is root-owned 0440 (unreadable by a non-root app), so
        // verify the rule covers lowpowermode via `sudo -n -l` (lists granted commands).
        return run("/usr/bin/sudo", ["-n", "-l"]).output.localizedCaseInsensitiveContains("lowpowermode")
    }

    /// Reads `pmset -g` and reports whether lid sleep is currently disabled.
    static func sleepDisabled() -> Bool {
        let output = run("/usr/bin/pmset", ["-g"]).output
        let patterns = [#"SleepDisabled\s+1"#, #"disablesleep\s+1"#]
        for pattern in patterns {
            if output.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    // MARK: Install (one-time admin prompt)

    static func ensureInstalled() async -> Bool {
        if isConfigured() { return true }
        return await install()
    }

    static func install() async -> Bool {
        do {
            try rule().write(toFile: tempFile, atomically: true, encoding: .utf8)
            chmod(tempFile, 0o440)
        } catch {
            return false
        }

        // Validate syntax, then install as root. The `&&` chain only copies the
        // file if `visudo` accepts it, so a bad rule can never reach sudoers.d.
        let script = "/usr/sbin/visudo -c -f '\(tempFile)' && /bin/cp '\(tempFile)' '\(sudoersFile)' && /bin/chmod 440 '\(sudoersFile)' && /bin/rm -f '\(tempFile)'"

        do {
            _ = try await PrivilegedExec.runShellScript(script)
        } catch {
            try? FileManager.default.removeItem(atPath: tempFile)
            return false
        }
        return isConfigured()
    }

    // MARK: pmset commands (passwordless via the sudoers rule)

    static func pmsetDisableSleep(_ disable: Bool) async -> Bool {
        runSudoPmset(["disablesleep", disable ? "1" : "0"])
    }

    static func pmsetDisableSleepSync(_ disable: Bool) -> Bool {
        runSudoPmset(["disablesleep", disable ? "1" : "0"])
    }

    static func pmsetLowPowerMode(_ enable: Bool) async -> Bool {
        runSudoPmset(["lowpowermode", enable ? "1" : "0"])
    }

    static func pmsetLowPowerModeSync(_ enable: Bool) -> Bool {
        runSudoPmset(["lowpowermode", enable ? "1" : "0"])
    }

    private static func runSudoPmset(_ args: [String]) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args).exit == 0
    }

    private static func run(_ path: String, _ args: [String]) -> (exit: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "")
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}

/// Runs a shell script as root via a single standard admin prompt (osascript).
nonisolated enum PrivilegedExec {
    static func runShellScript(_ script: String) async throws {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        _ = try await runOsascript(appleScript)
    }

    private static func runOsascript(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: AppModelError.commandFailed(
                        message.isEmpty ? "Authentication was canceled." : message
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}