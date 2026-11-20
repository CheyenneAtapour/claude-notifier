// Claude Notifier: a menu bar item counting Claude Code sessions waiting for
// you, red for finished and green for blocked on you, and a dashboard of every
// open Claude session. Sessions are files in ~/.claude/notifier/sessions,
// written by hook.sh.
import AppKit
import Network
import Security
import SwiftUI

let notifierDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notifier")
let sessionsDir = notifierDir.appendingPathComponent("sessions")
let labelsFile = notifierDir.appendingPathComponent("labels.json")

/// Appends `message` to ~/.claude/notifier/notifier.log.
func log(_ message: String) {
    let url = notifierDir.appendingPathComponent("notifier.log")
    let line = Data("\(Date()) \(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else {
        try? line.write(to: url)
    }
}

// MARK: - Sessions

struct Session: Identifiable, Equatable {
    /// The session id, or the terminal for a session with no file yet.
    let id: String
    let file: URL?
    /// "working", "done" (finished its reply), "input" (blocked on you), or "idle" (nothing to report).
    var state: String
    let cwd: String
    let branch: String
    let tty: String
    let task: String
    var message: String
    let started: Date?
    let time: Date
    /// Background shells still running after its reply, as Claude Code's footer counts them.
    var shells = 0
    /// When its Claude process started.
    var opened: Date?
    /// Whether `id` is a Claude Code session id, so the session can be resumed or copied.
    var resumable = false

    /// When you last prompted it, or else when it was opened: the order within its status.
    var recency: Date { started ?? opened ?? .distantPast }

    var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }

    var path: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    var place: String { branch.isEmpty ? path : "\(path) (\(branch))" }

    func name(_ tabs: [String: TerminalTab]) -> String {
        let title = tabs[tty]?.title ?? ""
        if cwd.isEmpty { return title.isEmpty ? tty : title }
        return title.isEmpty ? folder : "\(folder) — \(title)"
    }
}

/// Everything one poll learns: the open sessions and Terminal's tabs.
struct Snapshot: Equatable {
    var sessions: [Session] = []
    var tabs: [String: TerminalTab] = [:]
    /// The Terminal tab you are looking at, if Terminal is in front.
    var focused: String?
}

/// One look at everything: the session files of open Claude sessions, plus one
/// for each running Claude with no file yet, and one read of Terminal's tabs.
/// A file whose terminal no longer runs Claude belongs to a closed session and
/// is skipped. Runs off the main thread.
func takeSnapshot() -> Snapshot {
    let running = claudeProcesses()
    let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
    let all: [Session] = files.filter { $0.pathExtension == "json" }.compactMap { url in
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tty = json["tty"] as? String ?? ""
        guard tty.isEmpty || running[tty] != nil else { return nil }
        var session = Session(
            id: url.deletingPathExtension().lastPathComponent,
            file: url,
            state: json["state"] as? String ?? "done",
            cwd: json["cwd"] as? String ?? "",
            branch: json["branch"] as? String ?? "",
            tty: tty,
            task: json["task"] as? String ?? "",
            message: json["message"] as? String ?? "",
            started: (json["started"] as? Double).map { Date(timeIntervalSince1970: $0) },
            time: Date(timeIntervalSince1970: json["time"] as? Double ?? 0)
        )
        session.opened = running[tty]?.opened
        session.resumable = true
        return session
    }
    // A terminal can hold a closed session's file and a newer session; keep the newest.
    var seen = Set<String>()
    var sessions = all.sorted { $0.time > $1.time }.filter { $0.tty.isEmpty || seen.insert($0.tty).inserted }
    for (tty, process) in running where !seen.contains(tty) {
        // Claude Code records each running process's session in ~/.claude/sessions/<pid>.json.
        let record = claudeSessionRecord(pid: process.pid)
        let (cwd, branch) = record.map { ($0.cwd, gitBranch($0.cwd)) } ?? place(of: process.pid)
        var session = Session(id: record?.id ?? tty, file: nil, state: "idle", cwd: cwd, branch: branch, tty: tty,
                              task: "", message: "", started: nil, time: .distantPast,
                              opened: record?.started ?? process.opened)
        session.resumable = record != nil
        sessions.append(session)
    }
    // What the screens show that no hook reports: a question or permission prompt
    // (such as the ones Claude asks while starting up) needs you; background shells
    // still running after a reply mean it is still working.
    let (tabs, focused) = Terminal.read(screensOf: Set(running.keys))
    for i in sessions.indices {
        guard let contents = tabs[sessions[i].tty]?.contents else { continue }
        let signal = Terminal.signals(contents)
        if signal.asking && sessions[i].state != "input" {
            sessions[i].state = "input"
            if sessions[i].message.isEmpty { sessions[i].message = "is asking you something" }
        } else if signal.shells > 0 && (sessions[i].state == "done" || sessions[i].state == "idle") {
            sessions[i].shells = signal.shells
            sessions[i].state = "working"
        }
    }
    // Those needing you first, then working, then done, then idle. Within each,
    // a session takes its place when it arrives, the one you prompted (or, never
    // prompted, opened) most recently first, and keeps it while it stays: prompting
    // a working session again does not move it. Ties go by terminal.
    let rank = ["input": 0, "working": 1, "done": 2]
    var placed: [String: Standing] = [:]
    for session in sessions {
        let r = rank[session.state] ?? 3
        if let old = standings[session.id], old.rank == r {
            placed[session.id] = old
        } else {
            placed[session.id] = Standing(rank: r, key: session.recency.timeIntervalSince1970)
        }
    }
    standings = placed
    sessions.sort {
        let a = placed[$0.id]!, b = placed[$1.id]!
        return (a.rank, -a.key, $0.tty, $0.id) < (b.rank, -b.key, $1.tty, $1.id)
    }
    return Snapshot(sessions: sessions, tabs: tabs, focused: focused)
}

/// A session's status group and its place in it, kept from poll to poll.
struct Standing {
    let rank: Int
    let key: Double
}

/// Each session's standing at the last poll. Only `takeSnapshot` uses it, one poll at a time.
var standings: [String: Standing] = [:]

/// The end of session `id`'s conversation, from Claude Code's transcript: your
/// last `turns` prompts and Claude's replies to them in full, each tool it used
/// on one line. Terminal keeps only the screenfuls Claude Code last drew, so its
/// scrollback can't reach back this far. Empty if there is no transcript.
func conversation(_ id: String, turns: Int = 6) -> String {
    let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard UUID(uuidString: id) != nil,
          let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil),
          let url = dirs.map({ $0.appendingPathComponent("\(id).jsonl") })
              .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
          let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    // Transcripts grow to hundreds of megabytes; the last few hold the turns wanted.
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 4_000_000 ? size - 4_000_000 : 0)
    var lines = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
    if size > 4_000_000, !lines.isEmpty { lines.removeFirst() }   // cut mid-line

    var parts: [String] = []   // per turn: its prompt, then the replies
    for line in lines {
        guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              entry["isMeta"] as? Bool != true, entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { continue }
        switch entry["type"] as? String {
        case "user":
            // Your prompts are plain text; tool results, notes and interruptions are not prompts.
            guard let text = message["content"] as? String,
                  !text.hasPrefix("<"), !text.hasPrefix("[Request interrupted") else { continue }
            parts.append("❯ " + text)
        case "assistant":
            guard !parts.isEmpty, let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                if block["type"] as? String == "text", let text = block["text"] as? String {
                    parts[parts.count - 1] += "\n\n⏺ " + text
                } else if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let about = (input["description"] ?? input["file_path"] ?? input["command"] ?? input["pattern"]) as? String ?? ""
                    let first = about.split(separator: "\n").first.map(String.init) ?? ""
                    // One line each, under the text before it.
                    parts[parts.count - 1] += "\n  ⎿ \(name)" + (first.isEmpty ? "" : ": \(first.prefix(120))")
                }
            }
        default: continue
        }
    }
    return parts.suffix(turns).joined(separator: "\n\n" + String(repeating: "─", count: 30) + "\n\n")
}

/// Runs `tool` with `arguments` and returns what it prints.
func output(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    // Read as it writes, so a long output can't fill the pipe and stall it; give up
    // after a few seconds, as on a folder macOS hasn't yet let this app read.
    var data = Data()
    let read = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        read.signal()
    }
    guard read.wait(timeout: .now() + 5) == .success else {
        kill(process.processIdentifier, SIGKILL)
        return ""
    }
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Running `claude` processes with a terminal, by device (e.g. /dev/ttys003): their pid and when they started.
func claudeProcesses() -> [String: (pid: Int, opened: Date)] {
    var processes: [String: (pid: Int, opened: Date)] = [:]
    for line in output("/bin/ps", ["-axo", "pid=,etime=,tty=,comm="]).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count == 4, parts[2] != "??", let pid = Int(parts[0]),
              parts[3].trimmingCharacters(in: .whitespaces).split(separator: "/").last == "claude" else { continue }
        processes["/dev/\(parts[2])"] = (pid, Date().addingTimeInterval(-elapsed(String(parts[1]))))
    }
    return processes
}

/// Seconds in a `ps` elapsed time, [[dd-]hh:]mm:ss.
func elapsed(_ text: String) -> TimeInterval {
    let dayParts = text.split(separator: "-")
    let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
    let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
    return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
}

/// The session id, directory and start time Claude Code records for a running process.
func claudeSessionRecord(pid: Int) -> (id: String, cwd: String, started: Date?)? {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions/\(pid).json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["sessionId"] as? String else { return nil }
    return (id, json["cwd"] as? String ?? "", (json["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
}

/// The git branch checked out in `dir`, looked up at most every 30 seconds; empty outside a repository.
var branches: [String: (branch: String, at: Date)] = [:]
func gitBranch(_ dir: String) -> String {
    if let known = branches[dir], Date().timeIntervalSince(known.at) < 30 { return known.branch }
    let branch = dir.isEmpty ? "" : output("/usr/bin/git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    branches[dir] = (branch, Date())
    return branch
}

/// A process's working directory and its git branch, cached by pid.
var places: [Int: (cwd: String, branch: String)] = [:]
func place(of pid: Int) -> (cwd: String, branch: String) {
    if let known = places[pid] { return known }
    let cwd = output("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? ""
    let branch = cwd.isEmpty ? "" : output("/usr/bin/git", ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    places[pid] = (cwd, branch)
    return (cwd, branch)
}

/// Where the session is up to; for a working one, a rough estimate of the time
/// left: the median time your past prompts took, less the time this one has run.
func estimate(_ session: Session) -> String {
    let ago = RelativeDateTimeFormatter()
    switch session.state {
    case "done": return "Finished \(ago.localizedString(for: session.time, relativeTo: Date()))"
    case "input": return "Waiting on you since \(ago.localizedString(for: session.time, relativeTo: Date()))"
    case "idle": return session.file == nil ? "No activity since the notifier started" : "Idle"
    default: break
    }
    if session.shells > 0 {
        return "Reply finished · \(session.shells) background shell\(session.shells == 1 ? "" : "s") running"
    }
    guard let started = session.started else { return "Working" }
    let elapsed = Date().timeIntervalSince(started)
    let ran = "Working for \(duration(elapsed))"
    let past = pastDurations().sorted()
    guard past.count >= 3 else { return "\(ran) · no estimate yet (needs a few finished prompts)" }
    let typical = past[past.count / 2]
    if elapsed < typical { return "\(ran) · rough ETA ~\(duration(typical - elapsed)) (typical prompt \(duration(typical)))" }
    return "\(ran) · longer than a typical prompt (\(duration(typical)))"
}

/// How long your recent finished prompts took, in seconds; read at most every 30 seconds.
var pastDurations: () -> [Double] = {
    if let cached = durationsCache, Date().timeIntervalSince(cached.at) < 30 { return cached.durations }
    let history = (try? String(contentsOf: notifierDir.appendingPathComponent("history.jsonl"), encoding: .utf8)) ?? ""
    let durations = history.split(separator: "\n").suffix(50).compactMap { line -> Double? in
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return json["seconds"] as? Double
    }
    durationsCache = (durations, Date())
    return durations
}
var durationsCache: (durations: [Double], at: Date)?

func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h \(s % 3600 / 60)m"
}

// MARK: - Terminal

struct TerminalTab: Equatable {
    /// The tab's own title (Claude Code sets the session's), without status symbols.
    let title: String
    /// The whole window title.
    let window: String
    /// The text on screen.
    let contents: String
    /// The tab's background and text colours.
    let background: Color
    let foreground: Color
}

enum Terminal {
    static let field = "\u{1F}", record = "\u{1E}"

    /// Each Terminal tab, by its terminal device, with the screens of the tabs on
    /// `ttys`; and the tab you are looking at, if Terminal is in front. One request
    /// to Terminal, made off the main thread.
    static func read(screensOf ttys: Set<String>) -> (tabs: [String: TerminalTab], focused: String?) {
        let wanted = ttys.map { "\"\($0)\"" }.joined(separator: ", ")
        let source = """
        tell application "Terminal"
            set out to ""
            try
                if frontmost then set out to tty of selected tab of front window
            end try
            set out to out & (character id 30)
            set wanted to {\(wanted)}
            repeat with w in windows
                try
                    repeat with t in tabs of w
                        set n to ""
                        if title displays custom title of t then set n to custom title of t
                        set c to ""
                        -- On a loop variable, `contents of` alone dereferences it and returns the tab.
                        if wanted contains (tty of t) then set c to contents of (contents of t)
                        set b to background color of t
                        set f to normal text color of t
                        set rgb to "" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 1 of f) & "," & (item 2 of f) & "," & (item 3 of f)
                        set out to out & (tty of t) & (character id 31) & n & (character id 31) & (name of w) & (character id 31) & rgb & (character id 31) & c & (character id 30)
                    end repeat
                end try
            end repeat
            return out
        end tell
        """
        guard let out = runInBackground(source) else { return ([:], nil) }
        var items = out.components(separatedBy: record)
        let focused = items.isEmpty ? "" : items.removeFirst()
        var tabs: [String: TerminalTab] = [:]
        for item in items {
            let parts = item.components(separatedBy: field)
            guard parts.count == 5 else { continue }
            // Terminal's colour components run from 0 to 65535.
            let c = parts[3].split(separator: ",").map { (Double($0) ?? 0) / 65535 }
            let colors = c.count == 6
                ? (Color(red: c[0], green: c[1], blue: c[2]), Color(red: c[3], green: c[4], blue: c[5]))
                : (Color(white: 0.1), Color(white: 0.92))
            tabs[parts[0]] = TerminalTab(title: clean(parts[1]), window: clean(parts[2]), contents: parts[4],
                                         background: colors.0, foreground: colors.1)
        }
        return (tabs, focused.isEmpty ? nil : focused)
    }

    static let shellCount = try! NSRegularExpression(pattern: "(\\d+) shells?\\b")
    static let choice = try! NSRegularExpression(pattern: "^\\s*[❯>] \\d+\\.", options: .anchorsMatchLines)
    static let hints = ["Enter to confirm", "Enter to select", "Esc to cancel", "Esc to exit"]

    /// From the bottom of a screen: whether Claude Code is showing a question or
    /// permission prompt, and how many background shells its footer says are
    /// still running ("· 1 shell", "· 2 shells still running").
    static func signals(_ contents: String) -> (asking: Bool, shells: Int) {
        let lines = contents.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // The status lines are at the bottom of the screen.
        let bottom = lines.suffix(6).joined(separator: "\n")
        let found = shellCount.matches(in: bottom, range: NSRange(bottom.startIndex..., in: bottom))
            .compactMap { Range($0.range(at: 1), in: bottom).flatMap { Int(bottom[$0]) } }
        return (asking(Array(lines.suffix(12)), hints: hints, choice: choice), found.max() ?? 0)
    }

    /// Whether the bottom `lines` of a screen show a question or permission
    /// prompt: its choices or key hints, in place of Claude Code's input box (a
    /// rule, a ❯ line that is not a numbered choice, a rule). Checking for the
    /// box keeps output that merely quotes the hints from counting.
    static func asking(_ lines: [String], hints: [String], choice: NSRegularExpression) -> Bool {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        func isChoice(_ line: String) -> Bool {
            choice.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        let inputBox = trimmed.indices.contains { i in
            guard trimmed[i].hasPrefix("──"), let next = trimmed[(i + 1)...].firstIndex(where: { !$0.isEmpty }),
                  trimmed[next].hasPrefix("❯"), !isChoice(trimmed[next]) else { return false }
            return trimmed[(next + 1)...].contains { $0.hasPrefix("──") }
        }
        if inputBox { return false }
        return trimmed.suffix(4).contains { line in hints.contains { line.contains($0) } } || trimmed.contains(where: isChoice)
    }

    /// The scrollback of the tab on `tty`, up to its last `lines` lines. Off the main thread.
    static func history(tty: String, lines: Int) -> String {
        let source = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then return history of t
                end repeat
            end repeat
            return ""
        end tell
        """
        return tail(runInBackground(source) ?? "", lines)
    }

    /// Raises the window whose tab is on `tty` and selects that tab; just
    /// brings Terminal forward if none is.
    static func focus(tty: String) {
        _ = run("""
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }

    /// Types `text` into the tab on `tty` and presses Return, as if you had
    /// typed it there. Line breaks become spaces: each would submit on its own.
    /// Claude Code can take text arriving all at once as a paste, Return and all,
    /// leaving it in the input box unsent. The box is checked for a few seconds,
    /// as Claude Code can take a moment to show it there, and Return is pressed
    /// again, on its own, while it is. Only then: a stray Return could answer a
    /// question Claude is asking.
    static func send(_ text: String, to tty: String) {
        type(text, to: tty)
        resend(to: tty, after: [0.5, 1, 1.5, 2]) { unsent(text, on: tty) }
    }

    /// Waits each of `delays` in turn, pressing Return whenever `stuck` (run off
    /// the main thread) says what was typed is still unsent.
    private static func resend(to tty: String, after delays: [Double], stuck: @escaping () -> Bool) {
        guard let delay = delays.first else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            let unsent = stuck()
            DispatchQueue.main.async {
                if unsent { type("", to: tty) }
                resend(to: tty, after: Array(delays.dropFirst()), stuck: stuck)
            }
        }
    }

    /// Whether Claude Code's input box on `tty` still holds `text` (or a paste
    /// placeholder for it). Runs off the main thread.
    static func unsent(_ text: String, on tty: String) -> Bool {
        let lines = screen(tty).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // The input box: the line starting ❯ under the last rule, and any wrapped lines after it.
        guard let rule = lines.indices.last(where: { i in
            lines[i].hasPrefix("──") && lines[(i + 1)...].first(where: { !$0.isEmpty })?.hasPrefix("❯") == true
        }) else { return false }
        let box = lines[(rule + 1)...].prefix { !$0.hasPrefix("──") }.joined(separator: " ")
        let start = String(text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(24))
        return box.contains("[Pasted text") || (!start.isEmpty && box.contains(start))
    }

    /// What the tab on `tty` shows now. Runs off the main thread.
    static func screen(_ tty: String) -> String {
        runInBackground("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then return contents of (contents of t)
                end repeat
            end repeat
            return ""
        end tell
        """) ?? ""
    }

    /// A menu of numbered options Claude Code is showing: a question it asks
    /// you, or a permission prompt.
    struct Menu {
        var options: [Int: String] = [:]
        var highlighted = 1

        /// Whether option `number` is one you type an answer into.
        func typed(_ number: Int) -> Bool {
            guard let label = options[number] else { return false }
            return label.hasPrefix("Type something") || label == "Other"
        }
    }

    /// The menu in `screen`, if one is open: the numbered lines above its
    /// "Esc to cancel" footer, back up to option 1.
    static func menu(in screen: String) -> Menu? {
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let footer = lines.lastIndex(where: { $0.contains("Esc to cancel") }) else { return nil }
        let option = try! NSRegularExpression(pattern: #"^(❯\s*)?([1-9])\.\s+(.+)$"#)
        var menu = Menu()
        for line in lines[..<footer].reversed() {
            guard let match = option.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let number = Int(line[Range(match.range(at: 2), in: line)!]), menu.options[number] == nil else { continue }
            menu.options[number] = String(line[Range(match.range(at: 3), in: line)!])
            if match.range(at: 1).location != NSNotFound { menu.highlighted = number }
            if number == 1 { break }
        }
        return menu.options.isEmpty ? nil : menu
    }

    /// Picks option `number` in `menu`, open on `tty`: arrows to it from the
    /// highlighted one, then `text` (for an option you type into) and Return.
    /// Arrows rather than its number key, as a number would go into a text
    /// option's box if that one were highlighted.
    /// An answer typed in can arrive as a paste whose Return doesn't submit it,
    /// as a prompt can (see `send`): while the option's own box still holds the
    /// answer, Return is pressed again. Only that box: the answer also shows in
    /// the conversation once sent, above any next menu, where a Return would pick
    /// that menu's highlighted option.
    static func choose(_ number: Int, text: String, in menu: Menu, on tty: String) {
        type(text, to: tty, arrows: number - menu.highlighted)
        guard !text.isEmpty else { return }
        let start = String(text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(24))
        resend(to: tty, after: [0.5, 1, 1.5, 2]) {
            guard let box = Terminal.menu(in: screen(tty))?.options[number] else { return false }
            return box.contains(start) || box.contains("[Pasted text")
        }
    }

    /// `do script`: types `text` into the tab on `tty`, then Return; first
    /// `arrows` presses of Down (or, negative, Up).
    private static func type(_ text: String, to tty: String, arrows: Int = 0) {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let arrow = "(ASCII character 27) & \"\(arrows > 0 ? "[B" : "[A")\" & "
        let keys = String(repeating: arrow, count: abs(arrows))
        _ = run("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        do script \(keys)"\(line)" in t
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }

    /// Exits the Claude session on `session.tty` (SIGTERM, as closing its
    /// window would), then closes the window once only its shell is left. A
    /// window with other tabs, or still running something else, stays open.
    static func close(_ session: Session) {
        guard let pid = claudeProcesses()[session.tty]?.pid else { return }
        kill(pid_t(pid), SIGTERM)
        DispatchQueue.global().async {
            for _ in 0..<50 where kill(pid_t(pid), 0) == 0 { usleep(100_000) }
            let exited = kill(pid_t(pid), 0) != 0
            DispatchQueue.main.async {
                guard exited else {
                    log("Claude Notifier: Claude (pid \(pid)) on \(session.tty) did not exit within 5 seconds")
                    return
                }
                if let file = session.file { try? FileManager.default.removeItem(at: file) }
                // Let the shell take over the tab before checking it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    _ = run("""
                    tell application "Terminal"
                        repeat with w in windows
                            repeat with t in tabs of w
                                if tty of t is "\(session.tty)" then
                                    if (count of tabs of w) is 1 and not (busy of t) then close w
                                    return
                                end if
                            end repeat
                        end repeat
                    end tell
                    """)
                }
            }
        }
    }

    /// Opens a Popcorn Terminal window (a random theme) in `dir`, running
    /// `command` there if given, else a plain shell.
    static func popcorn(in dir: String, running command: String? = nil) {
        let process = Process()
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/bin/popcorn-terminal")
        process.arguments = [dir] + (command.map { [$0] } ?? [])
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { log("Claude Notifier: could not open a Popcorn terminal: \(error)") }
    }

    /// Gives the tab on `tty` another random Popcorn theme, one already installed as a
    /// Terminal profile, and renames its window to match if it was named after the old
    /// theme. The running program carries on. Returns the new theme's name.
    @discardableResult
    static func reroll(tty: String) -> String? {
        let dir = ProcessInfo.processInfo.environment["POPCORN_THEMES"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/github/random/macos-terminal-themes/themes").path
        let themes = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".terminal") }
            .map { "\"\(String($0.dropLast(9)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
        guard !themes.isEmpty else { log("Claude Notifier: no Popcorn themes in \(dir)"); return nil }
        let name = run("""
        tell application "Terminal"
            set themes to {\(themes.joined(separator: ", "))}
            set installed to name of every settings set
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set old to name of current settings of t
                        set choices to {}
                        repeat with n in themes
                            if installed contains (contents of n) and (contents of n) is not old then set end of choices to (contents of n)
                        end repeat
                        if choices is {} then return ""
                        set theme to some item of choices
                        set current settings of t to settings set theme
                        if custom title of w is old then set custom title of w to theme
                        return theme
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """)
        return name?.isEmpty == false ? name : nil
    }

    /// Runs AppleScript through osascript, which is safe off the main thread
    /// (NSAppleScript is not). For the polls; actions you take use `run`.
    static func runInBackground(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return nil }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            log("Claude Notifier: AppleScript failed: \(String(decoding: failure, as: UTF8.self))")
            return nil
        }
        // osascript ends what it prints with a newline.
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log("Claude Notifier: AppleScript failed: \(error)") }
        return result?.stringValue
    }

    /// `text` without the changing status symbols Claude Code puts in titles
    /// (✳︎, ◐◑◒◓, spinner dots), its spaces collapsed.
    static func clean(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { s in
            !((0x25D0...0x25D3).contains(s.value) || (0x2700...0x27BF).contains(s.value)
                || (0x2800...0x28FF).contains(s.value) || s.properties.isEmojiPresentation)
        }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").joined(separator: " ")
    }

    /// The last `count` lines of `text` before Claude Code's input box (the
    /// rule above its ❯ line, and everything under it), without trailing blank lines.
    /// Only a box at the bottom counts, the rules above and below its ❯ line being
    /// the last two: while Claude shows a menu there is none, and an older box
    /// further up the scrollback would otherwise cut the menu off.
    static func tail(_ text: String, _ count: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        if let box = trimmed.indices.last(where: { i in
            trimmed[i].hasPrefix("──") && trimmed[(i + 1)...].first(where: { !$0.isEmpty })?.hasPrefix("❯") == true
        }), trimmed[box...].filter({ $0.hasPrefix("──") }).count <= 2 {
            lines.removeSubrange(box...)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(count).joined(separator: "\n")
    }
}

// MARK: - Dashboard

/// A label you gave a session, with its terminal and when its Claude started, to carry it over to the
/// session that replaces it in that same Claude.
struct SessionLabel: Codable, Equatable {
    var text: String
    var tty: String
    var opened: Double?
    /// One of `LabelColor.names`; purple when unset.
    var color: String?
}

/// The colours a label can have, Apple's system colours, by name.
enum LabelColor {
    static let names = ["purple", "pink", "red", "orange", "yellow", "green", "teal", "blue", "gray"]
    static let hex = [
        "purple": "#af52de", "pink": "#ff2d55", "red": "#ff3b30", "orange": "#ff9500", "yellow": "#ffcc00",
        "green": "#34c759", "teal": "#30b0c7", "blue": "#007aff", "gray": "#8e8e93",
    ]

    static func color(_ name: String?) -> Color {
        switch name {
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "blue": .blue
        case "gray": .gray
        default: .purple
        }
    }
}

final class DashboardModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var tabs: [String: TerminalTab] = [:]
    @Published var selected: Session?
    /// The selected session's scrollback, fetched in the background every few seconds.
    @Published var detail = ""
    /// The session you asked to close, awaiting your confirmation.
    @Published var closing: Session?
    /// Your labels for sessions, by session id; shown on the dashboard only.
    @Published var labels: [String: SessionLabel] = DashboardModel.loadLabels()
    /// Whether the dashboard is open, so polls update it.
    var visible = false
    private var fetching = false

    func label(_ session: Session) -> String { labels[session.id]?.text ?? "" }
    func labelColor(_ session: Session) -> String? { labels[session.id]?.color }

    /// Sets or (when blank) removes a session's label, and saves them all.
    /// Sets the session's label; its colour stays unless `color` is given.
    func setLabel(_ text: String, color: String? = nil, for session: Session) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = color.flatMap { LabelColor.names.contains($0) ? $0 : nil } ?? labels[session.id]?.color
        labels[session.id] = text.isEmpty ? nil
            : SessionLabel(text: text, tty: session.tty, opened: session.opened?.timeIntervalSince1970, color: color)
        saveLabels()
    }

    /// A session that starts afresh in the same Claude (after /clear, say) gets a new id;
    /// it keeps the label of the one it replaced, found by its terminal and Claude process.
    private func carryLabels() {
        var changed = false
        for session in sessions where labels[session.id] == nil {
            guard let opened = session.opened?.timeIntervalSince1970,
                  let (old, label) = labels.first(where: { id, label in
                      label.tty == session.tty && abs((label.opened ?? 0) - opened) < 2
                          && !sessions.contains { $0.id == id }
                  }) else { continue }
            labels[session.id] = label
            labels[old] = nil
            changed = true
        }
        if changed { saveLabels() }
    }

    private static func loadLabels() -> [String: SessionLabel] {
        guard let data = try? Data(contentsOf: labelsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: SessionLabel].self, from: data)) ?? [:]
    }

    private func saveLabels() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(labels).write(to: labelsFile, options: .atomic)
    }

    /// Takes in a poll's results, publishing only what changed, so views redraw only then.
    func apply(_ snapshot: Snapshot) {
        if sessions != snapshot.sessions {
            sessions = snapshot.sessions
            carryLabels()
        }
        if tabs != snapshot.tabs { tabs = snapshot.tabs }
        if let selected, let now = sessions.first(where: { $0.id == selected.id }), now != selected { self.selected = now }
    }

    func open(_ session: Session) {
        selected = session
        detail = ""
        fetchDetail()
    }

    /// Fetches the selected session's scrollback off the main thread.
    func fetchDetail() {
        guard let session = selected, !fetching else { return }
        fetching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let history = Terminal.history(tty: session.tty, lines: 400)
            DispatchQueue.main.async {
                self.fetching = false
                if self.selected?.id == session.id, self.detail != history { self.detail = history }
            }
        }
    }
}

/// The label and colour of a session's state.
func status(_ state: String) -> (label: String, color: Color) {
    switch state {
    case "working": ("Working", .blue)
    case "input": ("Needs you", .green)
    case "done": ("Done", .red)
    default: ("Idle", .gray)
    }
}

struct StatusPill: View {
    let state: String

    var body: some View {
        let (label, color) = status(state)
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

/// Your label for a session, as a tag beside its window's name.
struct LabelTag: View {
    let text: String
    var color: String?

    var body: some View {
        Label(text, systemImage: "tag.fill")
            .font(.caption.bold())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(LabelColor.color(color).opacity(0.15)))
            .foregroundStyle(LabelColor.color(color))
            // Its own height, but no wider than there is room for: a long label
            // ends in "…" rather than pushing the card's contents out of the card.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What closing `session` does, for the confirmation.
func closeMessage(_ session: Session) -> String {
    let what = session.cwd.isEmpty ? "this window" : "\(session.folder) (\(session.place))"
    var text = "Claude in \(what) will exit, and its Terminal window will close."
    if session.state == "working" { text += " It is working: that work stops." }
    if session.resumable { text += "\n\nThe conversation is kept. Resume it with:\nclaude --resume \(session.id)" }
    return text
}

/// The badge on a card counted in the menu bar: red for finished, green for needs you.
struct NotificationDot: View {
    let state: String

    var body: some View {
        if state == "done" || state == "input" {
            Circle()
                .fill(state == "done" ? Color.red : Color.green)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2.5))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .help(state == "done" ? "Finished: counted in the menu bar's red number" : "Needs you: counted in the menu bar's green number")
        }
    }
}

struct TerminalText: View {
    let text: String
    let size: CGFloat
    /// The terminal's own colours, if known.
    var tab: TerminalTab?
    /// Whether to shrink the text, down to a floor, until its longest line fits:
    /// a terminal far wider than its card would otherwise have every long line
    /// wrap again, breaking its tables and indents. A line still too wide at the
    /// floor wraps onto the next row.
    var fit = false

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(size: fitted(geometry.size.width - 16), design: .monospaced))
                        .foregroundStyle(tab?.foreground ?? Color(white: 0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("end")
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(tab?.background ?? Color(white: 0.1)))
    }

    /// The font size: `size`, or, fitting, smaller until the longest line fits `width`
    /// (a monospaced character is about 0.6 of the size wide), but no smaller than
    /// 6 points, below which it is unreadable.
    private func fitted(_ width: CGFloat) -> CGFloat {
        guard fit else { return size }
        let columns = text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 1
        return min(size, max(6, width / (CGFloat(max(columns, 1)) * 0.6)))
    }
}

struct SessionCard: View {
    let session: Session
    let tabs: [String: TerminalTab]
    var label = ""
    var labelColor: String?
    /// The card's size; its preview takes whatever height is left.
    let size: CGSize
    let open: () -> Void
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusPill(state: session.state)
                Text(session.name(tabs)).font(.headline).lineLimit(1)
                Spacer()
                Button("Bring to front") { Terminal.focus(tty: session.tty) }
                    .controlSize(.small)
                Button("Close…", role: .destructive) { close() }
                    .controlSize(.small)
                    .help("Exit Claude in this window and close it, after you confirm")
            }
            if !label.isEmpty || !session.cwd.isEmpty {
                HStack(spacing: 6) {
                    if !label.isEmpty { LabelTag(text: label, color: labelColor).layoutPriority(1) }
                    Text(session.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(session.task.isEmpty ? "No prompt seen yet" : session.task)
                .font(.callout).lineLimit(2)
                .foregroundStyle(session.task.isEmpty ? .secondary : .primary)
            if session.state == "input" {
                Text(session.message).font(.caption).foregroundStyle(.green).lineLimit(1)
            }
            Text(estimate(session)).font(.caption).foregroundStyle(.secondary)
            TerminalText(text: Terminal.tail(tabs[session.tty]?.contents ?? "", 40),
                         size: max(7, min(11, size.width / 48)), tab: tabs[session.tty], fit: true)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .padding(12)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(status(session.state).color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(status(session.state).color.opacity(0.35)))
        .overlay(alignment: .topTrailing) { NotificationDot(state: session.state).offset(x: 6, y: -6) }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

struct DetailView: View {
    @ObservedObject var model: DashboardModel
    let session: Session
    @State private var prompt: String
    @State private var label: String

    init(model: DashboardModel, session: Session, prompt: String = "") {
        self.model = model
        self.session = session
        _prompt = State(initialValue: prompt)
        _label = State(initialValue: model.label(session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.selected = nil } label: { Label("All sessions", systemImage: "chevron.left") }
                Spacer()
                Button("New Popcorn terminal here") { Terminal.popcorn(in: session.cwd) }
                    .disabled(session.cwd.isEmpty)
                    .help(session.cwd.isEmpty ? "This session's directory is unknown" : "A plain shell in \(session.path)")
                Button("Re-roll theme") { Terminal.reroll(tty: session.tty) }
                    .help("Give this window another random Popcorn theme")
                Button("Bring to front") { Terminal.focus(tty: session.tty) }
                    .keyboardShortcut(.defaultAction)
                Button("Close…", role: .destructive) { model.closing = session }
                    .help("Exit Claude in this window and close it, after you confirm")
            }
            HStack {
                StatusPill(state: session.state)
                Text(session.name(model.tabs)).font(.title3.bold()).lineLimit(1)
                if !label.trimmingCharacters(in: .whitespaces).isEmpty {
                    LabelTag(text: label.trimmingCharacters(in: .whitespaces), color: model.labelColor(session))
                }
            }
            HStack {
                Text("Label").foregroundStyle(.secondary)
                TextField("Label", text: $label, prompt: Text("Name this session on the dashboard…"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onChange(of: label) { _, new in model.setLabel(new, for: session) }
                if !label.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(LabelColor.names, id: \.self) { name in
                        let chosen = (model.labelColor(session) ?? "purple") == name
                        Circle()
                            .fill(LabelColor.color(name))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.primary, lineWidth: chosen ? 2 : 0).padding(-3))
                            .padding(3)
                            .contentShape(Circle())
                            .onTapGesture { model.setLabel(label, color: name, for: session) }
                            .help("Make the label \(name)")
                    }
                }
            }
            .help("Shown on its card in this dashboard; kept until you clear it")
            if !session.cwd.isEmpty { Text(session.place).font(.callout).foregroundStyle(.secondary) }
            if !session.task.isEmpty { Text(session.task).font(.callout).lineLimit(4) }
            if session.state == "input" { Text(session.message).foregroundStyle(.green) }
            Text(estimate(session)).font(.caption).foregroundStyle(.secondary)
            // The live screen stands in until the scrollback arrives.
            TerminalText(text: model.detail.isEmpty ? Terminal.tail(model.tabs[session.tty]?.contents ?? "", 400) : model.detail,
                         size: 11, tab: model.tabs[session.tty])
            HStack(alignment: .bottom) {
                TextField("Type a prompt for this session…", text: $prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .help("Typed into this session's terminal, then Return. If it is working, Claude queues it.")
        }
        .padding(16)
    }

    func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Terminal.send(text, to: session.tty)
        prompt = ""
    }
}

/// Starts Claude in a new Popcorn window: in a directory you choose (or create),
/// with fresh context or a copy of an open session's.
struct NewSessionView: View {
    @ObservedObject var model: DashboardModel
    @Binding var isPresented: Bool
    @State private var directory: String
    /// The session to copy the context of; nil for fresh context.
    @State private var source: String?

    init(model: DashboardModel, isPresented: Binding<Bool>,
         directory: String = FileManager.default.homeDirectoryForCurrentUser.path, source: String? = nil) {
        self.model = model
        _isPresented = isPresented
        _directory = State(initialValue: directory)
        _source = State(initialValue: source)
    }

    var forkable: [Session] { model.sessions.filter(\.resumable) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Claude session").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("Directory").font(.headline)
                HStack {
                    TextField("Directory", text: $directory).textFieldStyle(.roundedBorder)
                    Button("Choose…", action: choose)
                }
                Text("Choose… can also create a new folder.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Context").font(.headline)
                Picker("Context", selection: $source) {
                    Text("Fresh context").tag(String?.none)
                    ForEach(forkable) { session in
                        Text("Copy of \(session.name(model.tabs)) · \(session.place)").tag(Optional(session.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                Text("A copy starts with that session's whole conversation, then goes its own way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirectory(directory))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: isDirectory(directory) ? directory : NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    func start() {
        let path = (directory as NSString).expandingTildeInPath
        Terminal.popcorn(in: path, running: source.map { "claude --resume \($0) --fork-session" } ?? "claude")
        isPresented = false
    }

    /// Lets the screenshots show a demo folder that does not exist.
    static var anyDirectory = false

    func isDirectory(_ path: String) -> Bool {
        if NewSessionView.anyDirectory { return true }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &dir) && dir.boolValue
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        content.frame(minWidth: 520, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
            .alert(
                "Close this Claude session?",
                isPresented: Binding(get: { model.closing != nil }, set: { if !$0 { model.closing = nil } }),
                presenting: model.closing
            ) { session in
                Button("Close session", role: .destructive) {
                    if model.selected?.id == session.id { model.selected = nil }
                    Terminal.close(session)
                    model.closing = nil
                }
                Button("Cancel", role: .cancel) { model.closing = nil }
            } message: { session in
                Text(closeMessage(session))
            }
    }

    @State private var creating = false

    @ViewBuilder var content: some View {
        if let session = model.selected {
            DetailView(model: model, session: session)
                .id(session.id)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.sessions.count) Claude sessions").font(.headline)
                    Spacer()
                    Button { creating = true } label: { Label("New Claude session…", systemImage: "plus") }
                }
                .padding(.horizontal, GridLayout.spacing)
                .padding(.top, GridLayout.spacing)
                grid
            }
            .sheet(isPresented: $creating) { NewSessionView(model: model, isPresented: $creating) }
        }
    }

    @ViewBuilder var grid: some View {
        GeometryReader { geometry in
                let layout = GridLayout(count: model.sessions.count, in: geometry.size)
                let grid = LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(layout.card.width), spacing: GridLayout.spacing), count: layout.columns),
                    spacing: GridLayout.spacing
                ) {
                    ForEach(model.sessions) { session in
                        SessionCard(session: session, tabs: model.tabs, label: model.label(session), labelColor: model.labelColor(session), size: layout.card,
                                    open: { model.open(session) }, close: { model.closing = session })
                    }
                }
                .padding(GridLayout.spacing)
                if model.sessions.isEmpty {
                    Text("No Claude sessions are open.").foregroundStyle(.secondary).padding(40)
                } else if layout.fits {
                    grid.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { grid }
                }
            }
    }
}

/// The grid that fits every card in the window: the number of columns giving
/// the largest near-square cards. Only when they would be too small to read
/// does it fall back to a scrolling grid of readable cards.
struct GridLayout {
    static let spacing: CGFloat = 12
    static let smallest = CGSize(width: 280, height: 230)
    let columns: Int
    let card: CGSize
    let fits: Bool

    init(count: Int, in size: CGSize) {
        let n = max(count, 1), gap = GridLayout.spacing
        var best = (columns: 1, card: CGSize.zero, score: -CGFloat.infinity)
        for columns in 1...n {
            let rows = (n + columns - 1) / columns
            let width = (size.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            let height = (size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            // Prefer large cards that are close to square.
            let score = min(width, height * 1.1)
            if score > best.score { best = (columns, CGSize(width: width, height: height), score) }
        }
        let small = GridLayout.smallest
        if best.card.width >= small.width && best.card.height >= small.height {
            columns = best.columns
            // Cards no wider than about square, so a lone card is not a wide strip.
            card = CGSize(width: min(best.card.width, best.card.height * 1.4), height: best.card.height)
            fits = true
        } else {
            columns = max(1, Int((size.width - gap) / (small.width + gap)))
            card = small
            fits = false
        }
    }
}

// MARK: - Menu bar

final class Notifier: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let dashboard = DashboardModel()
    var window: NSWindow?
    var timer: Timer?
    /// The latest poll's results, which the menu bar, its menu and the dashboard all show.
    var snapshot = Snapshot()
    /// Polls run one at a time, off the main thread.
    let pollQueue = DispatchQueue(label: "claude-notifier.poll", qos: .utility)
    var polling = false
    var polls = 0
    /// Whether a poll has finished yet; the first only records which tab is in front.
    var primed = false
    /// You clicked while Terminal was in front: the next poll clears what you clicked in.
    var clicked = false
    /// Phone access, off until you turn it on from the menu.
    let remote = RemoteServer(webDir: Bundle.main.resourceURL?.appendingPathComponent("web")
        ?? URL(fileURLWithPath: "web"))
    /// Phone notifications through ntfy, off until you turn them on from the menu.
    let alerts = PhoneAlerts()

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateTitle()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        // A click in a Terminal window you are already looking at also counts
        // as seeing it. Watching clicks in other apps needs Accessibility access.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.clicked = true
                self?.poll()
            }
        }
        remote.perform = { [weak self] action in self?.perform(action) }
        if remote.config.enabled { remote.start() }
        // Lets a script open the dashboard too.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openDashboard), name: Notification.Name("com.cheyenne.claude-notifier.open"), object: nil)
    }

    /// Starts a poll in the background, unless one is running.
    func poll() {
        guard !polling else { return }
        polling = true
        pollQueue.async {
            let snapshot = takeSnapshot()
            DispatchQueue.main.async {
                self.polling = false
                self.update(snapshot)
            }
        }
    }

    func update(_ new: Snapshot) {
        let previous = snapshot.focused
        snapshot = new
        // Switching to a finished session's tab clears it; one already in front
        // when it finished stays until you click in it.
        if primed, let focused = new.focused, focused != previous || clicked { seen(focused) }
        primed = true
        clicked = false
        updateTitle()
        notifyPhone()
        if dashboard.visible {
            dashboard.apply(snapshot)
            // The scrollback is costly to fetch; every third poll is enough.
            polls += 1
            if polls % 3 == 0 { dashboard.fetchDetail() }
        }
        publishRemote()
    }

    /// Sends the phone the latest state, if phone access is on.
    func publishRemote() {
        guard remote.running else { return }
        // Labels carry over to a session's successor in apply, which the phone needs too.
        if !dashboard.visible { dashboard.apply(snapshot) }
        remote.subscribe = alerts.config.enabled ? alerts.subscribeLink : nil
        remote.publish(snapshot.sessions, tabs: snapshot.tabs, labels: dashboard.labels)
    }

    /// Tells the phone, through ntfy, which sessions need you or are done.
    func notifyPhone() {
        let tabs = snapshot.tabs
        alerts.update(snapshot.sessions, name: { [dashboard] session in
            let label = dashboard.label(session).trimmingCharacters(in: .whitespaces)
            return session.name(tabs) + (label.isEmpty ? "" : " [\(label)]")
        }, click: remote.running ? remote.addresses.first : nil)
    }

    /// Does what the phone asked.
    func perform(_ action: RemoteAction) {
        switch action {
        case .prompt(let session, let text): Terminal.send(text, to: session.tty)
        case .focus(let session): Terminal.focus(tty: session.tty)
        case .close(let session): Terminal.close(session)
        case .label(let session, let text, let color): dashboard.setLabel(text, color: color, for: session)
        case .choose(let session, let number, let text, let menu): Terminal.choose(number, text: text, in: menu, on: session.tty)
        case .seen(let session): if session.state == "done" { markIdle(session) }
        case .start(let directory, let source):
            Terminal.popcorn(in: directory, running: source.map { "claude --resume \($0) --fork-session" } ?? "claude")
        }
        publishRemote()
        poll()
    }

    func updateTitle() {
        let done = snapshot.sessions.filter { $0.state == "done" }.count
        let waiting = snapshot.sessions.filter { $0.state == "input" }.count
        let title = NSMutableAttributedString(string: "✳︎ Claude", attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
        for (count, color) in [(done, NSColor.systemRed), (waiting, NSColor.systemGreen)] where count > 0 {
            title.append(NSAttributedString(string: " ● \(count)", attributes: [
                .foregroundColor: color,
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            ]))
        }
        if item.button?.attributedTitle != title { item.button?.attributedTitle = title }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = snapshot.sessions.filter { $0.state == "done" || $0.state == "input" }
        let tabs = snapshot.tabs
        let inputs = list.filter { $0.state == "input" }.count
        let header = NSMenuItem(title: "Claude Notifier — \(list.count - inputs) done, \(inputs) need you", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let open = NSMenuItem(title: "Open Dashboard…", action: #selector(openDashboard), keyEquivalent: "d")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let ago = RelativeDateTimeFormatter()
        for session in list {
            let input = session.state == "input"
            let what = input ? (session.message.isEmpty ? "needs you" : session.message) : "done"
            let row = NSMenuItem(title: "", action: #selector(dismiss(_:)), keyEquivalent: "")
            let label = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: input ? NSColor.systemGreen : NSColor.systemRed])
            label.append(NSAttributedString(string: "\(session.name(tabs)) · \(session.place) · \(what), \(ago.localizedString(for: session.time, relativeTo: Date()))"))
            row.attributedTitle = label
            row.target = self
            row.representedObject = session
            let window = tabs[session.tty]?.window ?? ""
            row.toolTip = (window.isEmpty ? "" : "\(window)\n") + "\(session.place)\nClick to dismiss and bring its terminal to the front"
            menu.addItem(row)
        }
        if !list.isEmpty {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear all", action: #selector(clearAll), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        menu.addItem(.separator())
        menu.addItem(phoneMenu())
        menu.addItem(notificationsMenu())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Notifier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Phone Access: turn it on or off, and what to open on the phone.
    func phoneMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Phone Access", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Allow Phone Access", action: #selector(togglePhone), keyEquivalent: "")
        toggle.target = self
        toggle.state = remote.running ? .on : .off
        menu.addItem(toggle)
        if remote.running {
            menu.addItem(.separator())
            let addresses = remote.addresses
            let info = addresses.isEmpty ? ["Not on a network"] : addresses.map { "Open \($0) on your phone" }
            for line in info + ["Access code: \(remote.config.code)"] {
                let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
            let copy = NSMenuItem(title: "Copy Address", action: #selector(copyPhoneAddress), keyEquivalent: "")
            copy.target = self
            copy.isEnabled = !addresses.isEmpty
            menu.addItem(copy)
            menu.addItem(.separator())
            let code = NSMenuItem(title: "New Access Code (signs the phone out)", action: #selector(newPhoneCode), keyEquivalent: "")
            code.target = self
            menu.addItem(code)
        }
        item.submenu = menu
        return item
    }

    /// Phone Notifications: turn them on or off, and the ntfy topic to subscribe to.
    func notificationsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Phone Notifications", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Notify My Phone (ntfy)", action: #selector(toggleAlerts), keyEquivalent: "")
        toggle.target = self
        toggle.state = alerts.config.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        let server = alerts.config.server.replacingOccurrences(of: "https://", with: "")
        for line in ["In the ntfy app, subscribe to:", "\(alerts.config.topic)" + (server == "ntfy.sh" ? "" : " on \(server)")] {
            let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        for (title, action) in [("Copy Topic", #selector(copyTopic)), ("Send Test Notification", #selector(testAlerts))] {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
            row.target = self
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let topic = NSMenuItem(title: "New Topic (the phone must subscribe again)", action: #selector(newTopic), keyEquivalent: "")
        topic.target = self
        menu.addItem(topic)
        item.submenu = menu
        return item
    }

    @objc func toggleAlerts() {
        alerts.setEnabled(!alerts.config.enabled)
        notifyPhone()
        publishRemote()
    }

    @objc func copyTopic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(alerts.config.topic, forType: .string)
    }

    @objc func testAlerts() { alerts.test() }

    @objc func newTopic() { alerts.newTopic() }

    @objc func togglePhone() {
        remote.setEnabled(!remote.running)
        publishRemote()
    }

    @objc func copyPhoneAddress() {
        guard let address = remote.addresses.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    @objc func newPhoneCode() { remote.newCode() }

    /// Dismissing a finished session marks it idle; one blocked on you stays until it resumes.
    @objc func dismiss(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        if session.state == "done" { markIdle(session) }
        Terminal.focus(tty: session.tty)
    }

    @objc func clearAll() {
        for session in snapshot.sessions where session.state == "done" || session.state == "input" { markIdle(session) }
    }

    /// Clears the finished session on `tty`, which you are now looking at.
    func seen(_ tty: String) {
        for session in snapshot.sessions where session.tty == tty && session.state == "done" { markIdle(session) }
    }

    /// Keeps the session's file, so the dashboard still shows its task, but drops it from the counts.
    func markIdle(_ session: Session) {
        guard let url = session.file, let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["state"] = "idle"
        if let out = try? JSONSerialization.data(withJSONObject: json) { try? out.write(to: url) }
        // Show it now rather than at the next poll.
        if let i = snapshot.sessions.firstIndex(where: { $0.id == session.id }) {
            snapshot.sessions[i].state = "idle"
            updateTitle()
            notifyPhone()
            if dashboard.visible { dashboard.apply(snapshot) }
            publishRemote()
        }
    }

    @objc func openDashboard() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Claude Sessions"
            window.isReleasedWhenClosed = false
            // The hosting view would otherwise size the window to the grid's
            // natural width, which is next to nothing.
            let host = NSHostingView(rootView: DashboardView(model: dashboard))
            host.sizingOptions = []
            window.contentView = host
            window.contentMinSize = NSSize(width: 520, height: 400)
            window.delegate = self
            window.center()
            if !window.setFrameUsingName("ClaudeNotifierDashboardFrame") || window.frame.width < 520 {
                window.setContentSize(NSSize(width: 920, height: 680))
                window.center()
            }
            window.setFrameAutosaveName("ClaudeNotifierDashboardFrame")
            self.window = window
        }
        dashboard.visible = true
        dashboard.apply(snapshot)
        poll()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        dashboard.visible = false
        dashboard.selected = nil
    }
}

// MARK: - Phone access

/// What the phone asks the Mac to do. The server hands these to the main thread.
enum RemoteAction {
    case prompt(Session, String)
    case focus(Session)
    case close(Session)
    case label(Session, String, String?)
    case choose(Session, Int, String, Terminal.Menu)
    case seen(Session)
    case start(directory: String, source: String?)
}

/// Phone access: a small web server for the phone's dashboard (web/index.html), off until you turn it
/// on from the menu. It answers only devices on your own networks (private addresses: your Wi-Fi,
/// Tailscale), and only after the access code: a right code sets a cookie, too many wrong ones lock it
/// for a minute. Everything here runs on its own queue; actions go to the main thread.
final class RemoteServer {
    struct Config: Codable {
        var enabled = false
        var port: UInt16 = 7878
        var code = ""
        var token = ""
    }

    static let file = notifierDir.appendingPathComponent("remote.json")
    private(set) var config: Config
    var running: Bool { listener != nil }
    /// Where the page's files are: the app's Resources/web, or the repo's web/ when testing.
    let webDir: URL
    /// Carries out what the phone asks, on the main thread.
    var perform: (RemoteAction) -> Void = { _ in }
    /// A session's scrollback; run off the main thread.
    var history: (Session) -> String = { Terminal.history(tty: $0.tty, lines: 400) }
    var screen: (Session) -> String = { Terminal.screen($0.tty) }
    var transcript: (Session) -> String = { conversation($0.id) }
    /// Gives a session's tab another theme, on the main thread; returns the theme's name.
    var reroll: (Session) -> String? = { Terminal.reroll(tty: $0.tty) }
    /// Only for the demo: answer on this computer alone.
    var localOnly = false
    /// The ntfy link that subscribes the phone to its notifications, while they are on.
    var subscribe: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "claude-notifier.remote")
    // On `queue`: the latest state for the phone, its version, the sessions it was made from,
    // the phone's requests waiting for a change, and recent wrong codes.
    private var state = Data()
    private var version = 0
    private var sessions: [Session] = []
    private var waiting: [(connection: NWConnection, id: Int)] = []
    private var nextWaiter = 0
    private var failures: [Date] = []

    init(webDir: URL, config: Config? = nil) {
        self.webDir = webDir
        if let config {
            self.config = config
        } else if let data = try? Data(contentsOf: RemoteServer.file),
                  let saved = try? JSONDecoder().decode(Config.self, from: data) {
            self.config = saved
        } else {
            self.config = Config()
        }
        if self.config.code.isEmpty || self.config.token.isEmpty { newCode(save: config == nil) }
    }

    /// A new access code, which also signs out any phone signed in with the old one.
    func newCode(save: Bool = true) {
        let letters = Array("ACDEFGHJKMNPQRTUVWXY3479")
        var code = String((0..<8).map { _ in letters[Int.random(in: 0..<letters.count)] })
        code.insert("-", at: code.index(code.startIndex, offsetBy: 4))
        config.code = code
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        config.token = bytes.map { String(format: "%02x", $0) }.joined()
        if save { self.save() }
    }

    func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
        save()
        enabled ? start() : stop()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        FileManager.default.createFile(atPath: RemoteServer.file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if localOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port) }
        do {
            let listener = localOnly ? try NWListener(using: parameters) : try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { log("Claude Notifier: phone access stopped: \(error)") }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log("Claude Notifier: could not start phone access on port \(config.port): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            for waiter in self.waiting { waiter.connection.cancel() }
            self.waiting = []
        }
    }

    /// The Mac's addresses on your networks, for the phone to open.
    var addresses: [String] {
        var found: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if RemoteServer.isPrivate(ip) { found.append("http://\(ip):\(config.port)") }
        }
        return found
    }

    // MARK: State

    /// Takes in a poll's results; a phone waiting for a change gets it now.
    func publish(_ sessions: [Session], tabs: [String: TerminalTab], labels: [String: SessionLabel]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let list: [[String: Any]] = sessions.map { session in
            let tab = tabs[session.tty]
            return [
                "id": session.id,
                "state": session.state,
                "status": status(session.state).label,
                "name": session.name(tabs),
                "label": labels[session.id]?.text ?? "",
                "labelColor": LabelColor.hex[labels[session.id]?.color ?? "purple"] ?? "",
                "place": session.place,
                "path": session.path,
                "task": session.task,
                "message": session.message,
                "estimate": estimate(session),
                "preview": Terminal.tail(tab?.contents ?? "", 30),
                "background": hex(tab?.background) ?? "#1e1e1e",
                "foreground": hex(tab?.foreground) ?? "#e6e6e6",
                "resumable": session.resumable,
                // How many options a menu Claude shows has, so the phone's Alt keys pick them only then.
                "options": Terminal.menu(in: tab?.contents ?? "")?.options.count ?? 0,
            ]
        }
        let dirs = Array(Set(sessions.map(\.path).filter { !$0.isEmpty })).sorted()
        queue.async {
            var body: [String: Any] = ["sessions": list, "directories": dirs, "home": home]
            if let subscribe = self.subscribe { body["subscribe"] = subscribe }
            guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
            self.sessions = sessions
            guard data != self.state else { return }
            self.state = data
            self.version += 1
            let waiting = self.waiting
            self.waiting = []
            for waiter in waiting { self.sendState(waiter.connection) }
        }
    }

    private func hex(_ color: Color?) -> String? {
        guard let color, let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    private func sendState(_ connection: NWConnection) {
        var body = Data("{\"version\":\(version),\"state\":".utf8)
        body.append(state.isEmpty ? Data("{\"sessions\":[]}".utf8) : state)
        body.append(Data("}".utf8))
        respond(connection, 200, body)
    }

    // MARK: HTTP

    struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = Data()

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }

        var cookie: String? {
            headers["cookie"]?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("cn=") }.map { String($0.dropFirst(3)) }
        }
    }

    /// Whether `ip` is on one of your own networks: private, Tailscale's, link-local or this Mac.
    static func isPrivate(_ ip: String) -> Bool {
        var ip = ip.lowercased()
        if let zone = ip.firstIndex(of: "%") { ip = String(ip[..<zone]) }
        if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        return ip == "::1" || ip.hasPrefix("fe8") || ip.hasPrefix("fe9") || ip.hasPrefix("fea") || ip.hasPrefix("feb")
            || ip.hasPrefix("fc") || ip.hasPrefix("fd")
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint, RemoteServer.isPrivate("\(host)") else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(connection, Data())
    }

    /// Reads one request (headers, then the body its Content-Length gives), at most 1 MB.
    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                var request = Request()
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = head.first?.split(separator: " ") ?? []
                if first.count >= 2 {
                    request.method = String(first[0])
                    let target = String(first[1])
                    let pieces = target.split(separator: "?", maxSplits: 1)
                    request.path = String(pieces.first ?? "/")
                    if pieces.count > 1 {
                        for pair in pieces[1].split(separator: "&") {
                            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                            if kv.count == 2 { request.query[kv[0]] = kv[1] }
                        }
                    }
                }
                for line in head.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    request.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = min(Int(request.headers["content-length"] ?? "") ?? 0, 1 << 20)
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    request.body = Data(body.prefix(length))
                    self.handle(request, connection)
                    return
                }
            }
            if complete || error != nil || buffer.count > (1 << 20) + 8192 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer)
        }
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ body: Data, type: String = "application/json",
                         headers: [String] = []) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 429: "Too Many Requests"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        for header in headers { head += header + "\r\n" }
        var data = Data((head + "\r\n").utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ json: [String: Any], headers: [String] = []) {
        respond(connection, status, (try? JSONSerialization.data(withJSONObject: json)) ?? Data(), headers: headers)
    }

    private func signedIn(_ request: Request) -> Bool {
        guard let given = request.cookie else { return false }
        let a = Array(given.utf8), b = Array(config.token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func handle(_ request: Request, _ connection: NWConnection) {
        // The page and its files need no code; everything under /api does.
        if request.method == "GET", !request.path.hasPrefix("/api/") {
            let files = ["/": ("index.html", "text/html; charset=utf-8"),
                         "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
                         "/icon.svg": ("icon.svg", "image/svg+xml")]
            guard let (name, type) = files[request.path],
                  let data = try? Data(contentsOf: webDir.appendingPathComponent(name)) else {
                return respond(connection, 404, ["error": "Not found"])
            }
            return respond(connection, 200, data, type: type)
        }
        if request.path == "/api/login", request.method == "POST" { return login(request, connection) }
        guard signedIn(request) else { return respond(connection, 401, ["error": "Enter the access code"]) }
        let body = request.json
        let session = (body["id"] as? String ?? request.query["id"]).flatMap { id in sessions.first { $0.id == id } }

        switch (request.method, request.path) {
        case ("GET", "/api/state"):
            // Answers at once if the phone's copy is out of date, else when something changes (or
            // after 25 seconds), so the phone sees changes as they happen.
            if Int(request.query["v"] ?? "") != version || state.isEmpty { return sendState(connection) }
            nextWaiter += 1
            let id = nextWaiter
            waiting.append((connection, id))
            queue.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, let i = self.waiting.firstIndex(where: { $0.id == id }) else { return }
                self.waiting.remove(at: i)
                self.sendState(connection)
            }
        case ("GET", "/api/transcript"):
            guard let session else { return respond(connection, 404, ["error": "No such session"]) }
            DispatchQueue.global(qos: .userInitiated).async {
                let text = self.transcript(session)
                self.queue.async { self.respond(connection, 200, ["text": text]) }
            }
        case ("GET", "/api/history"):
            guard let session else { return respond(connection, 404, ["error": "No such session"]) }
            DispatchQueue.global(qos: .userInitiated).async {
                let text = self.history(session)
                self.queue.async { self.respond(connection, 200, ["text": text]) }
            }
        case ("POST", "/api/choose"):
            // An option you type into first answers needsText; the phone asks you, then sends it again with text.
            guard let session else { return respond(connection, 404, ["error": "No such session"]) }
            guard let number = body["option"] as? Int, (1...9).contains(number) else {
                return respond(connection, 400, ["error": "No such option"])
            }
            let text = String((body["text"] as? String ?? "").filter { !$0.isASCII || $0.asciiValue! >= 32 }.prefix(20000))
            DispatchQueue.global(qos: .userInitiated).async {
                guard let menu = Terminal.menu(in: self.screen(session)), let label = menu.options[number] else {
                    return self.queue.async { self.respond(connection, 409, ["error": "No option \(number) to choose"]) }
                }
                let typed = menu.typed(number)
                if typed && text.trimmingCharacters(in: .whitespaces).isEmpty {
                    return self.queue.async { self.respond(connection, 200, ["needsText": true, "label": label]) }
                }
                DispatchQueue.main.async {
                    self.perform(.choose(session, number, typed ? text : "", menu))
                    self.queue.async { self.respond(connection, 200, ["ok": true, "label": label]) }
                }
            }
        case ("POST", "/api/prompt"):
            let text = (body["text"] as? String ?? "").filter { !$0.isASCII || $0.asciiValue! >= 32 || $0 == "\n" }
            guard let session, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return respond(connection, 400, ["error": "Nothing to send"])
            }
            act(.prompt(session, String(text.prefix(20000))), connection)
        case ("POST", "/api/focus"):
            guard let session else { return respond(connection, 404, ["error": "No such session"]) }
            act(.focus(session), connection)
        case ("POST", "/api/theme"):
            guard let session else { return respond(connection, 404, ["error": "No such session"]) }
            DispatchQueue.main.async {
                let theme = self.reroll(session)
                self.queue.async {
                    if let theme { self.respond(connection, 200, ["ok": true, "theme": theme]) }
                    else { self.respond(connection, 409, ["error": "No other theme to pick"]) }
                }
            }
        case ("POST", "/api/close"):
            guard let session else { return respond(connection, 404, ["error": "No such session"]) }
            act(.close(session), connection)
        case ("POST", "/api/label"):
            guard let session else { return respond(connection, 404, ["error": "No such session"]) }
            act(.label(session, String((body["text"] as? String ?? "").prefix(80)), body["color"] as? String), connection)
        case ("POST", "/api/seen"):
            guard let session else { return respond(connection, 404, ["error": "No such session"]) }
            act(.seen(session), connection)
        case ("POST", "/api/start"):
            let path = ((body["directory"] as? String ?? "") as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                guard body["create"] as? Bool == true, path.hasPrefix("/"),
                      (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil else {
                    return respond(connection, 400, ["error": "No such folder"])
                }
            } else if !isDirectory.boolValue {
                return respond(connection, 400, ["error": "That is a file, not a folder"])
            }
            let source = (body["source"] as? String).flatMap { id in sessions.first { $0.id == id && $0.resumable }?.id }
            act(.start(directory: path, source: source), connection)
        default:
            respond(connection, 404, ["error": "Not found"])
        }
    }

    private func act(_ action: RemoteAction, _ connection: NWConnection) {
        DispatchQueue.main.async {
            self.perform(action)
            self.queue.async { self.respond(connection, 200, ["ok": true]) }
        }
    }

    private func login(_ request: Request, _ connection: NWConnection) {
        failures.removeAll { Date().timeIntervalSince($0) > 60 }
        guard failures.count < 5 else {
            return respond(connection, 429, ["error": "Too many wrong codes; try again in a minute"])
        }
        let normal = { (s: String) in s.uppercased().filter { $0.isLetter || $0.isNumber } }
        guard normal(request.json["code"] as? String ?? "") == normal(config.code) else {
            failures.append(Date())
            return respond(connection, 401, ["error": "That code is not right"])
        }
        respond(connection, 200, ["ok": true],
                headers: ["Set-Cookie: cn=\(config.token); Max-Age=31536000; Path=/; HttpOnly; SameSite=Strict"])
    }
}

// MARK: - Phone notifications

/// Notifies your phone through ntfy (https://ntfy.sh) when a session needs you or finishes, off
/// until you turn it on from the menu. Each session has one notification, replaced when its status
/// changes and deleted once it no longer counts: you saw it, answered it, or closed it. Only the
/// session's name and status go out, never prompts or output, since anyone who knows the topic
/// can read them.
final class PhoneAlerts {
    struct Config: Codable {
        var enabled = false
        var server = "https://ntfy.sh"
        var topic = ""
        /// Seconds a status must last before the phone hears of it, so a quick answer doesn't buzz.
        var delay: TimeInterval = 10
    }

    struct Sent: Codable {
        var state: String
        /// ntfy's id for the notification. Each is used once: the phone ignores a message
        /// reusing the id of one it deleted.
        var sequence: String
    }

    static let file = notifierDir.appendingPathComponent("ntfy.json")
    /// What the phone was last told, kept so a restart can still remove those notifications.
    static let sentFile = notifierDir.appendingPathComponent("ntfy-sent.json")
    private(set) var config: Config
    /// What the phone was last told for each session, and statuses still waiting out the delay.
    private var sent: [String: Sent] = [:] {
        didSet { try? JSONEncoder().encode(sent).write(to: PhoneAlerts.sentFile) }
    }
    private var pending: [String: (state: String, since: Date)] = [:]
    /// The first update after starting only notes what already counts, so a restart doesn't buzz.
    private var primed = false

    init() {
        if let data = try? Data(contentsOf: PhoneAlerts.file),
           let saved = try? JSONDecoder().decode(Config.self, from: data) {
            config = saved
        } else {
            config = Config()
        }
        if config.topic.isEmpty { newTopic() }
        if let data = try? Data(contentsOf: PhoneAlerts.sentFile),
           let saved = try? JSONDecoder().decode([String: Sent].self, from: data) {
            sent = saved
        }
    }

    /// A new random topic; the phone has to subscribe to it again.
    func newTopic() {
        clearAll()
        let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
        config.topic = "claude-" + String((0..<20).map { _ in letters[Int.random(in: 0..<letters.count)] })
        save()
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled { clearAll() }
        config.enabled = enabled
        primed = false
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        FileManager.default.createFile(atPath: PhoneAlerts.file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Brings the phone in line with the sessions that count, after each poll.
    func update(_ sessions: [Session], name: (Session) -> String, click: String?) {
        guard config.enabled else { return }
        var counting: [String: Session] = [:]
        for session in sessions where session.state == "done" || session.state == "input" { counting[session.id] = session }
        guard primed else {
            for (id, session) in counting where sent[id] == nil { sent[id] = Sent(state: session.state, sequence: "") }
            primed = true
            return
        }
        for (id, notice) in sent where counting[id] == nil {
            delete(notice.sequence)
            sent[id] = nil
        }
        pending = pending.filter { counting[$0.key]?.state == $0.value.state }
        let now = Date()
        for (id, session) in counting where sent[id]?.state != session.state {
            guard let since = pending[id]?.since else {
                pending[id] = (session.state, now)
                continue
            }
            guard now.timeIntervalSince(since) >= config.delay else { continue }
            let input = session.state == "input"
            // A status change replaces the session's notification; a new one gets a new id.
            let sequence = sent[id].flatMap { $0.sequence.isEmpty ? nil : $0.sequence } ?? fresh(id)
            send([
                "title": name(session),
                "message": input ? (session.message.isEmpty ? "Needs you" : "Needs you: \(session.message)") : "Done",
                "tags": [input ? "bell" : "white_check_mark"],
                "priority": input ? 4 : 3,
                "sequence_id": sequence,
            ].merging(click.map { ["click": "\($0)/#\(id)"] } ?? [:]) { a, _ in a })
            sent[id] = Sent(state: session.state, sequence: sequence)
            pending[id] = nil
        }
    }

    /// Opens the ntfy app on an Android phone, subscribed to this topic.
    var subscribeLink: String {
        let server = config.server.replacingOccurrences(of: "https://", with: "")
        let insecure = server.hasPrefix("http://")
        return "ntfy://\(server.replacingOccurrences(of: "http://", with: ""))/\(config.topic)?display=Claude+sessions" + (insecure ? "&secure=false" : "")
    }

    func test() {
        send(["title": "Claude Notifier", "message": "Phone notifications work", "tags": ["white_check_mark"], "sequence_id": "test"])
    }

    /// Deletes every notification this sent, as when turning it off.
    private func clearAll() {
        for notice in sent.values { delete(notice.sequence) }
        sent = [:]
        pending = [:]
    }

    /// A new ntfy id for a session's notification: letters, digits, - and _.
    private func fresh(_ id: String) -> String {
        let session = id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(40)
        return "s\(session)_" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    }

    private func send(_ message: [String: Any]) {
        guard let url = URL(string: config.server) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: message.merging(["topic": config.topic]) { a, _ in a })
        perform(request)
    }

    private func delete(_ sequence: String) {
        guard !sequence.isEmpty, let url = URL(string: "\(config.server)/\(config.topic)/\(sequence)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        perform(request)
    }

    private func perform(_ request: URLRequest) {
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || !(200..<300).contains(status) {
                log("Claude Notifier: ntfy \(request.httpMethod ?? "") failed: \(error.map { "\($0)" } ?? "status \(status)")")
            }
        }.resume()
    }
}

// MARK: - Screenshots

/// `ClaudeNotifier --screenshots <dir>` draws the dashboard's views offscreen,
/// with demo sessions, into PNGs for the README. No screen capture is involved.
enum Screenshots {
    static func demo() -> (sessions: [Session], tabs: [String: TerminalTab]) {
        let now = Date()
        // Under the home folder, so paths show as ~/code/….
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func session(_ tty: String, _ state: String, _ cwd: String, _ branch: String, _ task: String,
                     message: String = "", started: TimeInterval? = nil, ago: TimeInterval) -> Session {
            Session(id: "demo-\(tty)", file: URL(fileURLWithPath: "/demo/\(tty).json"), state: state,
                    cwd: home + "/code/\(cwd)", branch: branch, tty: "/dev/\(tty)", task: task, message: message,
                    started: started.map { now.addingTimeInterval(-$0) }, time: now.addingTimeInterval(-ago), resumable: true)
        }
        let sessions = [
            session("ttys001", "input", "weather-app", "feat/radar", "Add a radar overlay to the map view and cache the tiles",
                    message: "Claude needs your permission to use Bash", started: 380, ago: 40),
            session("ttys002", "working", "api-server", "fix/rate-limit", "Fix the 429s the rate limiter returns under bursts of traffic",
                    started: 250, ago: 250),
            session("ttys003", "done", "blog", "main", "Write the release notes for v2.3 from the PRs merged since v2.2",
                    started: 900, ago: 120),
            Session(id: "demo-idle", file: nil, state: "idle", cwd: home + "/code/scratch", branch: "", tty: "/dev/ttys004",
                    task: "", message: "", started: nil, time: .distantPast),
        ]
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
        let tabs: [String: TerminalTab] = [
            "/dev/ttys001": TerminalTab(title: "Radar overlay", window: "weather-app — Radar overlay — claude — 160×48", contents: """
            ⏺ I'll fetch the tile manifest to size the cache.

            ╭──────────────────────────────────────────────────────╮
            │ Bash command                                         │
            │   curl -s https://tiles.example.com/radar/manifest   │
            │ Do you want to proceed?                              │
            │ ❯ 1. Yes                                             │
            │   2. Yes, and don't ask again for curl               │
            │   3. No, and tell Claude what to do differently      │
            ╰──────────────────────────────────────────────────────╯
            """, background: rgb(40, 42, 54), foreground: rgb(248, 248, 242)),
            "/dev/ttys002": TerminalTab(title: "Rate limit fix", window: "api-server — Rate limit fix — claude — 160×48", contents: """
            ⏺ The limiter refills its bucket once a second, so a burst of
              50 requests at 0.9s empties it before the refill.

            ⏺ Update(src/limiter.ts)
              ⎿  Updated src/limiter.ts with 6 additions and 2 removals

            ⏺ Bash(npm test -- limiter)
              ⎿  PASS  test/limiter.test.ts
                   ✓ allows a burst of 50 within the window (12 ms)
                   ✓ refills continuously instead of once a second (8 ms)

            ✻ Running the full suite…
            """, background: rgb(16, 31, 52), foreground: rgb(205, 220, 240)),
            "/dev/ttys003": TerminalTab(title: "Release notes", window: "blog — Release notes — claude — 160×48", contents: """
            ⏺ Wrote posts/2024-release-2-3.md:

              ## What's new in 2.3
              - Offline mode for saved articles (#412)
              - Faster search, about 3x on large blogs (#398)
              - Dark mode follows the system setting (#405)

              Fixed: broken RSS dates, image captions in dark mode.

            ✻ Cooked for 15m 2s · done 3:41 PM
            """, background: rgb(12, 36, 24), foreground: rgb(222, 240, 226)),
            "/dev/ttys004": TerminalTab(title: "", window: "scratch — claude — 120×40", contents: "you@mac scratch % claude",
                                        background: rgb(30, 30, 30), foreground: rgb(220, 220, 220)),
        ]
        return (sessions, tabs)
    }

    /// Draws `view` in an offscreen window titled `title` and saves it as a PNG.
    static func save<V: View>(_ view: V, title: String, size: NSSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        // The frame view includes the title bar.
        let frame = window.contentView!.superview!
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pastDurations = { [300, 420, 540, 600, 720] }
        let (sessions, tabs) = demo()
        let model = DashboardModel()
        model.labels = [sessions[1].id: SessionLabel(text: "Rate limiter", tty: sessions[1].tty)]
        model.sessions = sessions
        model.tabs = tabs
        save(DashboardView(model: model), title: "Claude Sessions", size: NSSize(width: 980, height: 720),
             to: dir.appendingPathComponent("dashboard.png"))

        let working = sessions[1]
        model.selected = working
        model.detail = tabs[working.tty]!.contents
        save(DetailView(model: model, session: working, prompt: "Also add a test for two bursts back to back"),
             title: "Claude Sessions", size: NSSize(width: 860, height: 600), to: dir.appendingPathComponent("detail.png"))

        model.selected = nil
        NewSessionView.anyDirectory = true
        save(NewSessionView(model: model, isPresented: .constant(true), directory: "~/code/weather-app-v2",
                            source: sessions[0].id),
             title: "New Claude session", size: NSSize(width: 560, height: 330), to: dir.appendingPathComponent("new-session.png"))
    }
}

let app = NSApplication.shared
// Serves the phone page with the screenshots' demo sessions, on this computer only, for trying it out:
//   ClaudeNotifier --serve-demo <port> <web dir>    (the access code is DEMO-CODE)
if let flag = CommandLine.arguments.firstIndex(of: "--serve-demo"), CommandLine.arguments.count > flag + 2 {
    app.setActivationPolicy(.prohibited)
    let (sessions, tabs) = Screenshots.demo()
    var labels = [sessions[1].id: SessionLabel(text: "Rate limiter", tty: sessions[1].tty)]
    let server = RemoteServer(webDir: URL(fileURLWithPath: CommandLine.arguments[flag + 2]),
                              config: .init(enabled: true, port: UInt16(CommandLine.arguments[flag + 1]) ?? 7879,
                                            code: "DEMO-CODE", token: UUID().uuidString))
    server.localOnly = true
    // The demo's own screens, never a real terminal's.
    server.history = { tabs[$0.tty]?.contents ?? "" }
    server.screen = { tabs[$0.tty]?.contents ?? "" }
    server.perform = { action in
        if case .label(let session, let text, let color) = action {
            labels[session.id] = text.isEmpty ? nil : SessionLabel(text: text, tty: session.tty, color: color ?? labels[session.id]?.color)
        }
        print("demo: \(action)")
        server.publish(sessions, tabs: tabs, labels: labels)
    }
    server.start()
    server.publish(sessions, tabs: tabs, labels: labels)
    app.run()
}
if let flag = CommandLine.arguments.firstIndex(of: "--screenshots"), CommandLine.arguments.count > flag + 1 {
    app.setActivationPolicy(.accessory)
    Screenshots.run(into: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(0)
}
let delegate = Notifier()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
