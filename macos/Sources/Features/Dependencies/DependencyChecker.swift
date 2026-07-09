import AppKit
import Foundation

/// A recommended external command-line tool that MyGhost relies on.
struct RecommendedTool {
    /// The executable name to look up on the user's PATH, e.g. "tmux".
    let name: String
    /// A short description of what MyGhost uses the tool for.
    let purpose: String
    /// A hint for how to install it, e.g. "brew install tmux".
    let installHint: String
}

/// Checks for recommended external tools and, on launch, prompts the user once
/// if any are missing. The prompt offers to remind them again next launch or to
/// snooze the reminder for 30 days. Once a missing tool is installed it drops
/// out of the list automatically, so the prompt stops appearing on its own.
enum DependencyChecker {
    /// The tools MyGhost recommends installing. tmux backs terminal session
    /// persistence (tabs survive quitting the app), so it is the primary one.
    /// Add more entries here as new features grow external dependencies.
    static let recommended: [RecommendedTool] = [
        RecommendedTool(
            name: "tmux",
            purpose: "Terminal session persistence — tabs survive quitting the app",
            installHint: "brew install tmux"
        ),
    ]

    /// UserDefaults key holding the earliest time (seconds since the reference
    /// date) the prompt may be shown again. Absent or in the past means the
    /// prompt is eligible to show.
    private static let remindAfterKey = "MissingToolsRemindAfter"

    /// How long "Remind Me in 30 Days" snoozes the prompt.
    private static let snoozeInterval: TimeInterval = 30 * 24 * 60 * 60

    /// Standard executable locations to search, plus the inherited login PATH.
    private static var searchDirectories: [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        return dirs
    }

    /// Whether an executable named `name` can be found on disk.
    static func isInstalled(_ name: String) -> Bool {
        let fm = FileManager.default
        for dir in searchDirectories {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return true }
        }
        return false
    }

    /// The recommended tools that are not currently installed.
    static func missingTools() -> [RecommendedTool] {
        recommended.filter { !isInstalled($0.name) }
    }

    /// Show the missing-tools prompt if any recommended tool is missing and the
    /// user has not snoozed the reminder. Safe to call once at launch; it does
    /// nothing when everything is installed or a snooze is still active.
    ///
    /// Presents an app-modal alert, so call it on the main thread (ideally
    /// deferred until after the initial windows are up).
    static func checkAndPromptIfNeeded() {
        let now = Date().timeIntervalSinceReferenceDate

        // Respect an active snooze.
        let remindAfter = UserDefaults.standard.double(forKey: remindAfterKey)
        if remindAfter > now { return }

        let missing = missingTools()
        guard !missing.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Some recommended tools are missing"
        let lines = missing.map { "•  \($0.name) — \($0.purpose)\n     Install with: \($0.installHint)" }
        alert.informativeText =
            "MyGhost works best with these command-line tools installed:\n\n"
            + lines.joined(separator: "\n\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Remind Me Next Time")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Remind Me in 30 Days")  // .alertSecondButtonReturn

        let response = alert.runModal()
        switch response {
        case .alertSecondButtonReturn:
            // Snooze for 30 days.
            UserDefaults.standard.set(now + snoozeInterval, forKey: remindAfterKey)
        default:
            // "Remind Me Next Time": clear any snooze so the prompt returns on
            // the next launch (until the tools are installed).
            UserDefaults.standard.removeObject(forKey: remindAfterKey)
        }
    }
}
