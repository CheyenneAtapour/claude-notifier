// Claude Notifier: a menu bar item counting Claude Code sessions waiting for
// you, red for finished and green for blocked on you, and a dashboard of every
// open Claude session. Sessions are files in ~/.claude/notifier/sessions,
// written by hook.sh.
import AppKit
import SwiftUI

let notifierDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notifier")
let sessionsDir = notifierDir.appendingPathComponent("sessions")

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
    // Those needing you first, then working, then done, then idle; within each,
    // the one you prompted (or, never prompted, opened) most recently first.
    // Ties go by terminal, so they keep their places between refreshes.
    let rank = ["input": 0, "working": 1, "done": 2]
    sessions.sort {
        (rank[$0.state] ?? 3, -$0.recency.timeIntervalSince1970, $0.tty, $0.id)
            < (rank[$1.state] ?? 3, -$1.recency.timeIntervalSince1970, $1.tty, $1.id)
    }
    return Snapshot(sessions: sessions, tabs: tabs, focused: focused)
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
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return out
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
    static func send(_ text: String, to tty: String) {
        let line = text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = run("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        do script "\(line)" in t
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
    static func tail(_ text: String, _ count: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        if let box = trimmed.indices.last(where: { i in
            trimmed[i].hasPrefix("──") && trimmed[(i + 1)...].first(where: { !$0.isEmpty })?.hasPrefix("❯") == true
        }) {
            lines.removeSubrange(box...)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(count).joined(separator: "\n")
    }
}

// MARK: - Dashboard

final class DashboardModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var tabs: [String: TerminalTab] = [:]
    @Published var selected: Session?
    /// The selected session's scrollback, fetched in the background every few seconds.
    @Published var detail = ""
    /// The session you asked to close, awaiting your confirmation.
    @Published var closing: Session?
    /// Whether the dashboard is open, so polls update it.
    var visible = false
    private var fetching = false

    /// Takes in a poll's results, publishing only what changed, so views redraw only then.
    func apply(_ snapshot: Snapshot) {
        if sessions != snapshot.sessions { sessions = snapshot.sessions }
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: size, design: .monospaced))
                    .foregroundStyle(tab?.foreground ?? Color(white: 0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .id("end")
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(tab?.background ?? Color(white: 0.1)))
    }
}

struct SessionCard: View {
    let session: Session
    let tabs: [String: TerminalTab]
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
            if !session.cwd.isEmpty {
                Text(session.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(session.task.isEmpty ? "No prompt seen yet" : session.task)
                .font(.callout).lineLimit(2)
                .foregroundStyle(session.task.isEmpty ? .secondary : .primary)
            if session.state == "input" {
                Text(session.message).font(.caption).foregroundStyle(.green).lineLimit(1)
            }
            Text(estimate(session)).font(.caption).foregroundStyle(.secondary)
            TerminalText(text: Terminal.tail(tabs[session.tty]?.contents ?? "", 40),
                         size: max(7, min(11, size.width / 48)), tab: tabs[session.tty])
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
        .help("Click for a larger view")
    }
}

struct DetailView: View {
    @ObservedObject var model: DashboardModel
    let session: Session
    @State private var prompt: String

    init(model: DashboardModel, session: Session, prompt: String = "") {
        self.model = model
        self.session = session
        _prompt = State(initialValue: prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.selected = nil } label: { Label("All sessions", systemImage: "chevron.left") }
                Spacer()
                Button("New Popcorn terminal here") { Terminal.popcorn(in: session.cwd) }
                    .disabled(session.cwd.isEmpty)
                    .help(session.cwd.isEmpty ? "This session's directory is unknown" : "A plain shell in \(session.path)")
                Button("Bring to front") { Terminal.focus(tty: session.tty) }
                    .keyboardShortcut(.defaultAction)
                Button("Close…", role: .destructive) { model.closing = session }
                    .help("Exit Claude in this window and close it, after you confirm")
            }
            HStack {
                StatusPill(state: session.state)
                Text(session.name(model.tabs)).font(.title3.bold()).lineLimit(1)
            }
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
                        SessionCard(session: session, tabs: model.tabs, size: layout.card,
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
        if dashboard.visible {
            dashboard.apply(snapshot)
            // The scrollback is costly to fetch; every third poll is enough.
            polls += 1
            if polls % 3 == 0 { dashboard.fetchDetail() }
        }
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
        menu.addItem(NSMenuItem(title: "Quit Claude Notifier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

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
            if dashboard.visible { dashboard.apply(snapshot) }
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
if let flag = CommandLine.arguments.firstIndex(of: "--screenshots"), CommandLine.arguments.count > flag + 1 {
    app.setActivationPolicy(.accessory)
    Screenshots.run(into: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(0)
}
let delegate = Notifier()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
