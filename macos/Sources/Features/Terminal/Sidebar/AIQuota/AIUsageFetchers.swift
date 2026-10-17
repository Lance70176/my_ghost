import CryptoKit
import Foundation
import Security

enum AIUsageFetchError: LocalizedError {
    case noCredential(String)
    case httpError(Int, String)
    /// 401: the credential was rejected — usually an access token the CLI
    /// hasn't refreshed because it hasn't been run lately.
    case unauthorized(String)
    /// 429, with the server's Retry-After in seconds when it sent one.
    case rateLimited(retryAfter: TimeInterval?, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noCredential(let msg): return msg
        case .httpError(let code, let body):
            let detail = body.isEmpty ? "" : ": \(body.prefix(120))"
            return "HTTP \(code)\(detail)"
        case .unauthorized(let body):
            return "HTTP 401" + (body.isEmpty ? "" : ": \(body.prefix(120))")
        case .rateLimited(_, let body):
            return "HTTP 429" + (body.isEmpty ? "" : ": \(body.prefix(120))")
        case .badResponse(let msg): return msg
        }
    }
}

/// What caused a usage fetch, recorded in the request log so a burst of
/// requests (and the 429s it earns) can be traced back to its source.
enum AIUsageTrigger: String {
    case timer      // the periodic auto-refresh
    case appear     // the sidebar section appearing
    case button     // the section's ⟳ button
    case row        // clicking an account row
    case settings   // saving an account in settings

    /// Fired without the user asking, so it should back off after errors.
    var isAutomatic: Bool { self == .timer || self == .appear }
}

/// Appends one line per usage request to
/// Application Support/MyGhost/ai_usage.log. The usage endpoints rate-limit
/// per account, and other clients (the Claude Code CLI, the web frontend)
/// share that budget, so the log is how to tell whether a 429 followed our
/// own traffic or someone else's.
enum AIUsageRequestLog {
    private static let maxBytes = 1_000_000
    private static let queue = DispatchQueue(label: "com.myghost.ai-usage-log")

    private static var fileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyGhost/ai_usage.log")
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    static func record(
        provider: String,
        trigger: AIUsageTrigger,
        start: Date,
        status: String,
        detail: String = ""
    ) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        var line = "\(timestampFormatter.string(from: start)) \(provider) trigger=\(trigger.rawValue) status=\(status) ms=\(ms)"
        if !detail.isEmpty { line += " \(detail)" }
        line += "\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let url = fileURL
        let fm = FileManager.default
        // Keep one previous generation so the log never grows unbounded.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}

/// Fetches usage for one account, dispatching on the provider.
enum AIUsageFetcher {
    static func fetch(
        for account: AIQuotaAccount,
        trigger: AIUsageTrigger
    ) async -> AIUsageSnapshot {
        do {
            let windows: [AIUsageWindow]
            switch account.provider {
            case .claudeCode:
                windows = try await ClaudeUsageFetcher.fetch(account: account, trigger: trigger)
            case .chatGPT:
                windows = try await ChatGPTUsageFetcher.fetch(account: account, trigger: trigger)
            case .antigravity:
                windows = try await AntigravityUsageFetcher.fetch(trigger: trigger)
            }
            return AIUsageSnapshot(windows: windows, fetchedAt: Date())
        } catch AIUsageFetchError.unauthorized {
            // Asking again with the same token only earns more 401s — and
            // enough of those get the token locked out with 429s for most of
            // an hour — so remember which token failed and wait for a new one.
            return AIUsageSnapshot(
                windows: [],
                fetchedAt: Date(),
                errorMessage: expiredMessage(for: account),
                rejectedCredential: await credentialFingerprint(for: account))
        } catch AIUsageFetchError.rateLimited(let retryAfter, _) {
            let resume = Date().addingTimeInterval(retryAfter ?? defaultRateLimitPause)
            return AIUsageSnapshot(
                windows: [],
                fetchedAt: Date(),
                errorMessage: L("Rate limited — auto-refresh paused until %@",
                                resume.formatted(date: .omitted, time: .shortened)),
                pausedUntil: resume)
        } catch {
            return AIUsageSnapshot(
                windows: [],
                fetchedAt: Date(),
                errorMessage: error.localizedDescription)
        }
    }

    /// How long to hold off after a 429 that carried no Retry-After.
    private static let defaultRateLimitPause: TimeInterval = 15 * 60

    private static func expiredMessage(for account: AIQuotaAccount) -> String {
        if account.authMode == .manualToken {
            return L("Token rejected — paste a new one in AI usage settings")
        }
        switch account.provider {
        case .claudeCode:
            return L("Claude Code login expired — open Claude Code once to refresh it")
        case .chatGPT:
            return L("Codex login expired — run codex once to refresh it")
        case .antigravity:
            return L("agy login expired — run agy once to sign in again")
        }
    }

    /// A hash of the token a fetch for this account would send right now, so
    /// a rejected token can be told apart from its refreshed replacement
    /// without keeping the token itself around.
    static func credentialFingerprint(for account: AIQuotaAccount) async -> String? {
        let token: String?
        switch account.provider {
        case .claudeCode:
            token = try? ClaudeUsageFetcher.resolveToken(account: account)
        case .chatGPT:
            token = try? ChatGPTUsageFetcher.resolveCredential(account: account).token
        case .antigravity:
            token = nil  // agy keeps its own login; never rejected here
        }
        guard let token else { return nil }
        return SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Shared helpers

    static func getJSON(
        url: URL,
        headers: [String: String],
        provider: String,
        trigger: AIUsageTrigger
    ) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            AIUsageRequestLog.record(
                provider: provider, trigger: trigger, start: start,
                status: "error", detail: "error=\"\(error.localizedDescription)\"")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            AIUsageRequestLog.record(
                provider: provider, trigger: trigger, start: start, status: "no-http")
            throw AIUsageFetchError.badResponse("No HTTP response")
        }
        AIUsageRequestLog.record(
            provider: provider, trigger: trigger, start: start,
            status: String(http.statusCode), detail: limitHeaders(http))
        guard (200..<300).contains(http.statusCode) else {
            // Prefer the API's own error message over the raw body (which can
            // be an HTML page when a proxy rejects the request).
            var detail = ""
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                detail = message
            }
            switch http.statusCode {
            case 401:
                throw AIUsageFetchError.unauthorized(detail)
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                throw AIUsageFetchError.rateLimited(retryAfter: retryAfter, detail)
            default:
                throw AIUsageFetchError.httpError(http.statusCode, detail)
            }
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// The response headers worth logging: anything describing a rate limit
    /// plus the request ID to quote when asking the provider about it.
    private static func limitHeaders(_ http: HTTPURLResponse) -> String {
        http.allHeaderFields
            .compactMap { key, value -> String? in
                guard let name = (key as? String)?.lowercased(),
                      name == "retry-after" || name == "request-id"
                        || name == "x-request-id" || name.contains("ratelimit")
                else { return nil }
                return "\(name)=\(value)"
            }
            .sorted()
            .joined(separator: " ")
    }

    static func parseISODate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Claude Code

/// Queries the Claude Code OAuth usage endpoint, the same one the CLI's
/// /usage command uses. Returns utilization per rate-limit window.
enum ClaudeUsageFetcher {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(
        account: AIQuotaAccount,
        trigger: AIUsageTrigger
    ) async throws -> [AIUsageWindow] {
        let token = try resolveToken(account: account)
        let json = try await AIUsageFetcher.getJSON(url: usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
        ], provider: "claude", trigger: trigger)
        guard let dict = json as? [String: Any] else {
            throw AIUsageFetchError.badResponse("Unexpected response shape")
        }

        // The response maps window names (five_hour, seven_day, seven_day_opus,
        // …) to {utilization, resets_at}. Parse tolerantly so new windows the
        // server adds still show up.
        let order = ["five_hour", "seven_day", "seven_day_fable", "seven_day_opus", "seven_day_sonnet"]
        var windows: [AIUsageWindow] = []
        let sortedKeys = dict.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count
            let ib = order.firstIndex(of: b) ?? order.count
            return ia == ib ? a < b : ia < ib
        }
        // The limits[] array repeats the session/weekly windows with their own
        // resets_at; five_hour/seven_day occasionally arrive with resets_at
        // null while the matching limits entry still carries the time, so keep
        // it as a fallback (kind "session" ↔ five_hour, "weekly_all" ↔ seven_day).
        let limits = dict["limits"] as? [[String: Any]] ?? []
        func limitResetsAt(kind: String) -> Date? {
            guard let limit = limits.first(where: { $0["kind"] as? String == kind }) else { return nil }
            return AIUsageFetcher.parseISODate(limit["resets_at"])
        }

        for key in sortedKeys {
            // extra_usage carries a monthly credit budget, not a rate-limit
            // window — only worth a row when the user has it enabled.
            if key == "extra_usage" {
                guard let value = dict[key] as? [String: Any],
                      value["is_enabled"] as? Bool == true else { continue }
            }
            guard let value = dict[key] as? [String: Any],
                  let utilization = value["utilization"] as? NSNumber
            else { continue }
            var resetsAt = AIUsageFetcher.parseISODate(value["resets_at"])
            if resetsAt == nil {
                switch key {
                case "five_hour": resetsAt = limitResetsAt(kind: "session")
                case "seven_day": resetsAt = limitResetsAt(kind: "weekly_all")
                default: break
                }
            }
            windows.append(AIUsageWindow(
                label: label(for: key),
                usedPercent: min(max(utilization.doubleValue, 0), 100),
                resetsAt: resetsAt))
        }

        // Per-model caps (e.g. the Fable weekly limit shown on claude.ai's
        // usage page) arrive as a `limits` array of scoped entries rather
        // than top-level windows: {group: "weekly", percent, resets_at,
        // scope: {model: {display_name: "Fable"}}}. Entries the API stops
        // sending simply disappear.
        for limit in limits {
            guard let percent = limit["percent"] as? NSNumber,
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty
            else { continue }
            windows.append(AIUsageWindow(
                label: name,
                usedPercent: min(max(percent.doubleValue, 0), 100),
                resetsAt: AIUsageFetcher.parseISODate(limit["resets_at"])))
        }

        guard !windows.isEmpty else {
            throw AIUsageFetchError.badResponse("No usage windows in response")
        }
        return windows
    }

    private static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "5h"
        case "seven_day": return "Week"
        case "extra_usage": return "Extra"
        default:
            // Per-model weekly windows (seven_day_fable, seven_day_opus, …)
            // label as the capitalized model name; windows the API stops
            // sending simply don't appear, so nothing else to special-case.
            if key.hasPrefix("seven_day_") {
                return String(key.dropFirst("seven_day_".count)).capitalized
            }
            return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func resolveToken(account: AIQuotaAccount) throws -> String {
        if account.authMode == .manualToken {
            let token = account.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw AIUsageFetchError.noCredential("No token configured")
            }
            return token
        }
        // Local login: Claude Code stores OAuth credentials in the keychain
        // (item "Claude Code-credentials"), with ~/.claude/.credentials.json
        // as an alternate location on some installs.
        if let json = keychainCredentialsJSON() ?? fileCredentialsJSON(),
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        throw AIUsageFetchError.noCredential(
            "Claude Code login not found (keychain / ~/.claude)")
    }

    private static func keychainCredentialsJSON() -> [String: Any]? {
        // Read via /usr/bin/security instead of SecItemCopyMatching: Claude
        // Code recreates this keychain item on every token refresh, wiping any
        // per-app "Always Allow" ACL entry — a direct API read would re-prompt
        // the user forever. The security tool is on the fresh item's ACL as
        // its creator, so this path reads without prompting.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    private static func fileCredentialsJSON() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - ChatGPT (Codex)

/// Queries the ChatGPT Codex usage endpoint using the OAuth token from the
/// Codex CLI login (~/.codex/auth.json) or a manually pasted token.
enum ChatGPTUsageFetcher {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!

    static func fetch(
        account: AIQuotaAccount,
        trigger: AIUsageTrigger
    ) async throws -> [AIUsageWindow] {
        let credential = try resolveCredential(account: account)
        // The Codex CLI User-Agent/originator headers are required — without
        // them Cloudflare rejects the request with an HTML 403 page.
        var headers = [
            "Authorization": "Bearer \(credential.token)",
            "Content-Type": "application/json",
            "User-Agent": "codex_cli_rs",
            "originator": "codex_cli_rs",
        ]
        if let accountID = credential.accountID {
            headers["chatgpt-account-id"] = accountID
        }
        let json = try await AIUsageFetcher.getJSON(
            url: usageURL, headers: headers, provider: "chatgpt", trigger: trigger)

        // Look for rate-limit windows anywhere in the response: objects with a
        // used_percent field, optionally window_minutes / resets_in_seconds.
        var windows: [AIUsageWindow] = []
        collectWindows(from: json, into: &windows, name: nil)
        guard !windows.isEmpty else {
            throw AIUsageFetchError.badResponse("No usage windows in response")
        }
        return windows
    }

    /// Walks the response for rate-limit windows, carrying down the name of
    /// the group each one turned up in so that windows of the same length
    /// still get labels that tell them apart.
    private static func collectWindows(
        from json: Any,
        into windows: inout [AIUsageWindow],
        name: String?
    ) {
        if let dict = json as? [String: Any] {
            // An additional_rate_limits entry names itself; windows nested
            // inside it inherit that name.
            let name = (dict["limit_name"] as? String) ?? name
            if let used = dict["used_percent"] as? NSNumber {
                // Window length and reset fields vary by schema version:
                // window_minutes / resets_in_seconds / resets_at (older) vs
                // limit_window_seconds / reset_after_seconds / reset_at.
                var minutes = (dict["window_minutes"] as? NSNumber)?.intValue
                if minutes == nil, let seconds = (dict["limit_window_seconds"] as? NSNumber)?.intValue {
                    minutes = seconds / 60
                }
                // Prefer the absolute timestamp: the relative field reports the
                // whole window length while a window is still unused, so it
                // drifts later on every refresh.
                var resetsAt: Date?
                if let resets = ((dict["resets_at"] ?? dict["reset_at"]) as? NSNumber)?.doubleValue {
                    resetsAt = Date(timeIntervalSince1970: resets)
                } else if let iso = AIUsageFetcher.parseISODate(dict["resets_at"] ?? dict["reset_at"]) {
                    resetsAt = iso
                } else if let seconds = ((dict["resets_in_seconds"] ?? dict["reset_after_seconds"]) as? NSNumber)?.doubleValue {
                    resetsAt = Date().addingTimeInterval(seconds)
                }
                windows.append(AIUsageWindow(
                    label: label(forMinutes: minutes, name: name, index: windows.count),
                    usedPercent: min(max(used.doubleValue, 0), 100),
                    resetsAt: resetsAt))
                return
            }
            // Visit primary before secondary so the 5h window lists first, and
            // the account's own limit before any add-on one — sorting the keys
            // plainly would lead with additional_rate_limits.
            for key in dict.keys.sorted(by: precedes) {
                collectWindows(
                    from: dict[key]!, into: &windows, name: groupName(for: key) ?? name)
            }
        } else if let array = json as? [Any] {
            for element in array {
                collectWindows(from: element, into: &windows, name: name)
            }
        }
    }

    private static let keyOrder = [
        "rate_limit", "code_review_rate_limit", "additional_rate_limits",
    ]

    private static func precedes(_ a: String, _ b: String) -> Bool {
        let ia = keyOrder.firstIndex(of: a) ?? keyOrder.count
        let ib = keyOrder.firstIndex(of: b) ?? keyOrder.count
        return ia == ib ? a < b : ia < ib
    }

    /// Names the groups that carry no limit_name of their own but would still
    /// produce a window the same length as the account's main one.
    private static func groupName(for key: String) -> String? {
        key == "code_review_rate_limit" ? "Review" : nil
    }

    /// Names a window after the group it belongs to when it has one: the
    /// account's own limit and an add-on like gpt-reserve are both a week
    /// long, so naming both after their period left two rows reading "Week".
    /// A window with no group falls back to the period it covers. The free
    /// plan's single window is a month long, so anything past a week can't
    /// just be called "Week" — that read as a weekly limit resetting 25 days
    /// out.
    private static func label(forMinutes minutes: Int?, name: String?, index: Int) -> String {
        if let name = shortName(name) { return name }
        guard let minutes else { return index == 0 ? "5h" : "Week" }
        if minutes <= 360 { return "5h" }
        let days = minutes / 1440
        if (6...8).contains(days) { return "Week" }
        if (27...32).contains(days) { return "Month" }
        if days >= 2 { return "\(days)d" }
        return "\(minutes / 60)h"
    }

    /// Shortens an API limit name to something the label column can hold, the
    /// way the Claude side names its per-model windows: the trailing word,
    /// capitalized ("gpt-reserve" → "Reserve"). A tail that is a bare number
    /// or a letter or two doesn't read on its own, so those keep every word.
    private static func shortName(_ name: String?) -> String? {
        guard let name else { return nil }
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        guard let tail = parts.last else { return nil }
        if parts.count > 1, tail.count >= 3, tail.contains(where: { $0.isLetter }) {
            return tail.capitalized
        }
        return parts.map { $0.capitalized }.joined(separator: " ")
    }

    static func resolveCredential(
        account: AIQuotaAccount
    ) throws -> (token: String, accountID: String?) {
        if account.authMode == .manualToken {
            let token = account.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw AIUsageFetchError.noCredential("No token configured")
            }
            let manualID = account.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token, manualID.isEmpty ? accountID(fromJWT: token) : manualID)
        }
        // Local login: Codex CLI stores tokens in ~/.codex/auth.json.
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else {
            throw AIUsageFetchError.noCredential(
                "Codex login not found (~/.codex/auth.json)")
        }
        let id = (tokens["account_id"] as? String) ?? accountID(fromJWT: token)
        return (token, id)
    }

    /// Extract the chatgpt_account_id claim from the access token JWT.
    private static func accountID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return auth["chatgpt_account_id"] as? String
    }
}

// MARK: - Antigravity (agy)

/// Asks the Antigravity CLI for its usage: `agy -p /usage --output-format
/// json` is a read-only command (no agent turn, no quota spent) that answers
/// with agy's own login, so no token is read here. Limits come in groups
/// (Gemini, Claude and GPT, Argon), each with a 5-hour and/or weekly window
/// reported as the fraction remaining.
enum AntigravityUsageFetcher {
    private static let candidates = [
        "~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
    ].map { NSString(string: $0).expandingTildeInPath }

    static func fetch(trigger: AIUsageTrigger) async throws -> [AIUsageWindow] {
        guard let agy = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AIUsageFetchError.noCredential(L("agy not found (~/.local/bin/agy)"))
        }
        let start = Date()
        let (status, out, err) = try await run(agy, ["-p", "/usage", "--output-format", "json"])
        guard status == 0,
              let json = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
        else {
            AIUsageRequestLog.record(provider: "antigravity", trigger: trigger, start: start,
                                     status: "exit-\(status)")
            let detail = (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIUsageFetchError.badResponse("agy: " + String(detail.suffix(160)))
        }
        AIUsageRequestLog.record(provider: "antigravity", trigger: trigger, start: start,
                                 status: (json["status"] as? String) ?? "?")
        guard json["status"] as? String == "SUCCESS",
              let data = (json["command"] as? [String: Any])?["data"] as? [String: Any],
              let groups = data["groups"] as? [[String: Any]]
        else {
            throw AIUsageFetchError.badResponse(L("agy couldn't read usage — is it signed in?"))
        }
        var windows: [AIUsageWindow] = []
        for group in groups {
            let name = shortName(group["name"] as? String ?? "")
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue else { continue }
                windows.append(AIUsageWindow(
                    label: "\(name) \(period(bucket["window"] as? String))",
                    usedPercent: min(max((1 - remaining) * 100, 0), 100),
                    resetsAt: AIUsageFetcher.parseISODate(bucket["reset_time"])))
            }
        }
        guard !windows.isEmpty else {
            throw AIUsageFetchError.badResponse("No usage windows in response")
        }
        return windows
    }

    /// Short enough for the sidebar's label column on one line:
    /// "Gemini Models" → Gem, "Claude and GPT models" → C/G,
    /// "Gemini 4 Argon" → Arg; anything new keeps its first three letters.
    private static func shortName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("argon") { return "Arg" }
        if lower.contains("claude") || lower.contains("gpt") { return "C/G" }
        if lower.contains("gemini") { return "Gem" }
        return String((name.split(separator: " ").first.map(String.init) ?? name).prefix(3))
    }

    private static func period(_ window: String?) -> String {
        switch window {
        case "5h": return "5h"
        case "weekly": return "Week"
        case let other?: return other
        case nil: return ""
        }
    }

    /// Runs agy off the main thread; gives up after 30 s.
    private static func run(_ path: String, _ args: [String]) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { p in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (p.terminationStatus, o, e))
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: AIUsageFetchError.badResponse("agy: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
