import AppKit
import ServiceManagement

// MARK: - 모델

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?

    var resetDate: Date? {
        guard let s = resets_at else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

struct UsageLimit: Decodable {
    struct Scope: Decodable {
        struct Model: Decodable { let display_name: String? }
        let model: Model?
    }
    let kind: String
    let percent: Double?
    let resets_at: String?
    let scope: Scope?

    var window: UsageWindow { UsageWindow(utilization: percent, resets_at: resets_at) }
}

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let limits: [UsageLimit]?
}

enum UsageError: Error {
    case noCredentials
    case unauthorized
    case http(Int)
    case other(String)

    var message: String {
        switch self {
        case .noCredentials: return "Claude Code 로그인 정보를 찾을 수 없음"
        case .unauthorized: return "토큰 만료 — Claude Code를 한 번 실행하면 갱신됩니다"
        case .http(let c): return "HTTP 오류 \(c)"
        case .other(let m): return m
        }
    }
}

// MARK: - 자격증명 (macOS 키체인의 Claude Code 토큰 사용)

enum Credentials {
    static func accessToken() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UsageError.noCredentials }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else { throw UsageError.noCredentials }
        return token
    }
}

// MARK: - API

enum UsageAPI {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> UsageResponse {
        let token = try Credentials.accessToken()
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw UsageError.unauthorized }
        guard code == 200 else { throw UsageError.http(code) }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }
}

// MARK: - 업데이트 (구글 드라이브 동기화 폴더의 latest.json 확인)

struct ReleaseInfo: Decodable {
    let version: String
    let build: Int
    let file: String
    let notes: String?
}

enum Updater {
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    /// ~/Library/CloudStorage/GoogleDrive-*/(내 드라이브|My Drive)/ClaudeUsageBar
    static func releaseFolder() -> URL? {
        let fm = FileManager.default
        let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let entries = try? fm.contentsOfDirectory(atPath: cloud.path) else { return nil }
        for entry in entries where entry.hasPrefix("GoogleDrive-") {
            let account = cloud.appendingPathComponent(entry)
            // 폴더명이 NFD로 저장되어 있어 정규화해서 비교
            for drive in (try? fm.contentsOfDirectory(atPath: account.path)) ?? []
            where ["내 드라이브", "My Drive"].contains(drive.precomposedStringWithCanonicalMapping) {
                let dir = account.appendingPathComponent(drive).appendingPathComponent("ClaudeUsageBar")
                if fm.fileExists(atPath: dir.appendingPathComponent("latest.json").path) { return dir }
            }
        }
        return nil
    }

    static func check() throws -> ReleaseInfo? {
        guard let dir = releaseFolder() else { throw UsageError.other("구글 드라이브 배포 폴더를 찾을 수 없음") }
        let data = try Data(contentsOf: dir.appendingPathComponent("latest.json"))
        let info = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        return info.build > currentBuild ? info : nil
    }

    /// 새 버전 압축 해제 → 앱 종료 후 교체 → 재실행
    static func install(_ info: ReleaseInfo) throws {
        guard let dir = releaseFolder() else { throw UsageError.other("배포 폴더 없음") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ClaudeUsageBarUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", dir.appendingPathComponent(info.file).path, tmp.path]
        try unzip.run()
        unzip.waitUntilExit()
        let newApp = tmp.appendingPathComponent("ClaudeUsageBar.app")
        guard unzip.terminationStatus == 0, fm.fileExists(atPath: newApp.path) else {
            throw UsageError.other("업데이트 파일 압축 해제 실패")
        }

        let target = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let log = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeUsageBar-update.log")
        // 종료 대기 → 새 앱을 옆에 복사한 뒤 교체(실패해도 기존 앱 유지) → 재실행 재시도
        let script = """
        exec >"$4" 2>&1
        echo "[$(date)] 업데이트 시작"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        sleep 1
        rm -rf "$1.new"
        /usr/bin/ditto "$2" "$1.new" || { echo "복사 실패"; open "$1"; exit 1; }
        rm -rf "$1" && mv "$1.new" "$1" || { echo "교체 실패"; exit 1; }
        /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        for i in 1 2 3 4 5; do
            open "$1" && sleep 2 && pgrep -x ClaudeUsageBar >/dev/null && { echo "재실행 성공 ($i회)"; break; }
            echo "재실행 재시도 $i"; sleep 2
        done
        rm -rf "$3"
        """
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", script, "sh", target, newApp.path, tmp.path, log.path]
        try sh.run()
        NSApp.terminate(nil)
    }
}

// MARK: - 표시 설정

enum DisplayMode: Int, CaseIterable {
    case both, fiveHour, weekly

    var title: String {
        switch self {
        case .both: return "5시간 + 주간"
        case .fiveHour: return "5시간만"
        case .weekly: return "주간만"
        }
    }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var usage: UsageResponse?
    private var lastError: UsageError?
    private var lastUpdated: Date?
    private var updateTimer: Timer?
    private var pendingUpdate: ReleaseInfo?
    private var updateStatus: String?

    private let defaults = UserDefaults.standard
    private var interval: TimeInterval {
        get { let v = defaults.double(forKey: "interval"); return v > 0 ? v : 60 }
        set { defaults.set(newValue, forKey: "interval") }
    }
    private var mode: DisplayMode {
        get { DisplayMode(rawValue: defaults.integer(forKey: "mode")) ?? .both }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.title = "Claude …"
        rebuildMenu()
        refresh()
        scheduleTimer()
        checkForUpdates(nil)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(nil)
        }
        // 잠자기에서 깨어나면 즉시 갱신
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 5
    }

    @objc private func refresh() {
        Task { @MainActor in
            do {
                usage = try await UsageAPI.fetch()
                lastError = nil
                lastUpdated = Date()
            } catch let e as UsageError {
                lastError = e
            } catch {
                lastError = .other(error.localizedDescription)
            }
            updateTitle()
            rebuildMenu()
        }
    }

    // MARK: 상태바 텍스트

    private func pct(_ w: UsageWindow?) -> Int? {
        guard let u = w?.utilization else { return nil }
        return Int(u.rounded())
    }

    // 남은 비율 (100 - 사용률)
    private func remaining(_ w: UsageWindow?) -> Int? {
        pct(w).map { max(0, 100 - $0) }
    }

    private func color(forRemaining r: Int) -> NSColor {
        switch r {
        case ..<11: return .systemRed
        case 11..<31: return .systemOrange
        default: return .labelColor
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let label = NSFont.systemFont(ofSize: 12, weight: .semibold)

        if usage == nil, lastError != nil {
            button.attributedTitle = NSAttributedString(
                string: "Claude ⚠", attributes: [.font: font])
            return
        }

        let s = NSMutableAttributedString()
        func add(_ tag: String, _ p: Int?) {
            if s.length > 0 { s.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            // 기간 라벨(5h/7d)은 흐리지 않게 기본 글자색(다크 메뉴바에서 흰색)으로
            s.append(NSAttributedString(string: tag + " ", attributes: [.font: label, .foregroundColor: NSColor.labelColor]))
            let text = p.map { "\($0)%" } ?? "–"
            s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color(forRemaining: p ?? 100)]))
        }
        if mode != .weekly { add("5h", remaining(usage?.five_hour)) }
        if mode != .fiveHour { add("7d", remaining(usage?.seven_day)) }
        if lastError != nil {
            s.append(NSAttributedString(string: " ⚠", attributes: [.font: font]))
        }
        if pendingUpdate != nil {
            s.append(NSAttributedString(string: " ↑", attributes: [.font: font, .foregroundColor: NSColor.systemBlue]))
        }
        button.attributedTitle = s
    }

    // MARK: 메뉴

    private func resetText(_ w: UsageWindow?) -> String {
        guard let d = w?.resetDate else { return "" }
        let secs = Int(d.timeIntervalSinceNow)
        guard secs > 0 else { return " · 곧 초기화" }
        let days = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        let left = days > 0 ? "\(days)일 \(h)시간" : (h > 0 ? "\(h)시간 \(m)분" : "\(m)분")
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = days > 0 ? "M/d(E) HH:mm" : "HH:mm"
        return " · \(left) 후 초기화 (\(f.string(from: d)))"
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func bar(_ p: Int?) -> String {
        guard let p else { return "" }
        let filled = min(10, max(0, Int((Double(p) / 10).rounded())))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: 10 - filled) + "  "
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        var rows: [(String, UsageWindow?)] = [
            ("5시간 세션", usage?.five_hour),
            ("주간 (전체 모델)", usage?.seven_day),
        ]
        // 모델별 주간 한도 (예: Fable, Opus)
        for l in usage?.limits ?? [] where l.kind == "weekly_scoped" {
            rows.append(("주간 (\(l.scope?.model?.display_name ?? "모델별"))", l.window))
        }
        for (name, w) in rows {
            guard let w, let p = pct(w), let r = remaining(w) else { continue }
            menu.addItem(info("\(name)"))
            menu.addItem(info("   \(bar(r))\(r)% 남음 (사용 \(p)%)\(resetText(w))"))
        }

        if let e = lastError {
            menu.addItem(.separator())
            menu.addItem(info("⚠ \(e.message)"))
        }
        if let t = lastUpdated {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            menu.addItem(.separator())
            menu.addItem(info("마지막 갱신 \(f.string(from: t))"))
        }

        menu.addItem(.separator())
        let r = NSMenuItem(title: "지금 새로고침", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)

        // 표시 방식
        let modeItem = NSMenuItem(title: "상태바 표시", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for m in DisplayMode.allCases {
            let i = NSMenuItem(title: m.title, action: #selector(setMode(_:)), keyEquivalent: "")
            i.target = self
            i.tag = m.rawValue
            i.state = m == mode ? .on : .off
            modeMenu.addItem(i)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 갱신 주기
        let intItem = NSMenuItem(title: "갱신 주기", action: nil, keyEquivalent: "")
        let intMenu = NSMenu()
        for (label, sec) in [("30초", 30.0), ("1분", 60.0), ("2분", 120.0), ("5분", 300.0)] {
            let i = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = sec
            i.state = sec == interval ? .on : .off
            intMenu.addItem(i)
        }
        intItem.submenu = intMenu
        menu.addItem(intItem)

        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // 업데이트
        menu.addItem(.separator())
        if let u = pendingUpdate {
            let i = NSMenuItem(title: "⬆ 업데이트 설치 (v\(u.version))", action: #selector(installUpdate), keyEquivalent: "")
            i.target = self
            menu.addItem(i)
            if let notes = u.notes, !notes.isEmpty { menu.addItem(info("   \(notes)")) }
        }
        let c = NSMenuItem(title: "업데이트 확인", action: #selector(checkForUpdates(_:)), keyEquivalent: "u")
        c.target = self
        menu.addItem(c)
        menu.addItem(info("현재 버전 v\(Updater.currentVersion) (\(Updater.currentBuild))" + (updateStatus.map { " · \($0)" } ?? "")))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        mode = DisplayMode(rawValue: sender.tag) ?? .both
        updateTitle()
        rebuildMenu()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Double else { return }
        interval = sec
        scheduleTimer()
        rebuildMenu()
    }

    /// sender가 nil이면 자동 확인(조용히), 메뉴에서 누르면 결과를 표시
    @objc private func checkForUpdates(_ sender: Any?) {
        do {
            pendingUpdate = try Updater.check()
            updateStatus = pendingUpdate == nil ? "최신 버전" : "새 버전 있음"
        } catch let e as UsageError {
            updateStatus = sender == nil ? nil : e.message
        } catch {
            updateStatus = sender == nil ? nil : error.localizedDescription
        }
        updateTitle()
        rebuildMenu()
    }

    @objc private func installUpdate() {
        guard let u = pendingUpdate else { return }
        do {
            try Updater.install(u)
        } catch let e as UsageError {
            updateStatus = e.message
            rebuildMenu()
        } catch {
            updateStatus = error.localizedDescription
            rebuildMenu()
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = .other("자동 실행 설정 실패: \(error.localizedDescription)")
        }
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
