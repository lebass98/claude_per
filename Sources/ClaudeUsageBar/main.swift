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
    case rateLimited(retryAfter: TimeInterval)
    case http(Int)
    case other(String)

    var message: String {
        switch self {
        case .noCredentials: return "Claude Code 로그인 정보를 찾을 수 없음"
        case .unauthorized: return "토큰 만료 — Claude Code를 한 번 실행하면 갱신됩니다"
        case .rateLimited: return "요청이 많아 잠시 제한됨(429) — 자동으로 간격을 늘려 재시도"
        case .http(let c): return "HTTP 오류 \(c)"
        case .other(let m): return m
        }
    }

    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
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
        if code == 429 {
            let after = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init) ?? 0
            throw UsageError.rateLimited(retryAfter: after)
        }
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

    /// ~/Library/CloudStorage/GoogleDrive-*/(내 드라이브|My Drive)/App/ClaudeUsageBar
    /// (예전 위치인 드라이브 바로 아래 ClaudeUsageBar도 함께 확인)
    static func releaseFolder() -> URL? {
        let fm = FileManager.default
        let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let entries = try? fm.contentsOfDirectory(atPath: cloud.path) else { return nil }
        for entry in entries where entry.hasPrefix("GoogleDrive-") {
            let account = cloud.appendingPathComponent(entry)
            // 폴더명이 NFD로 저장되어 있어 정규화해서 비교
            for drive in (try? fm.contentsOfDirectory(atPath: account.path)) ?? []
            where ["내 드라이브", "My Drive"].contains(drive.precomposedStringWithCanonicalMapping) {
                for sub in ["App/ClaudeUsageBar", "ClaudeUsageBar"] {
                    let dir = account.appendingPathComponent(drive).appendingPathComponent(sub)
                    if fm.fileExists(atPath: dir.appendingPathComponent("latest.json").path) { return dir }
                }
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
    // 429 백오프: 이 시각 전에는 요청하지 않음, 연속 실패마다 대기 시간 2배 (최대 10분)
    private var nextAllowedFetch = Date.distantPast
    private var backoff: TimeInterval = 0

    private let defaults = UserDefaults.standard
    private var interval: TimeInterval {
        // 30초 주기는 429를 유발해 최소 1분으로 제한
        get { max(60, defaults.double(forKey: "interval")) }
        set { defaults.set(newValue, forKey: "interval") }
    }
    private var mode: DisplayMode {
        get { DisplayMode(rawValue: defaults.integer(forKey: "mode")) ?? .both }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }
    /// 모델별 주간 한도(Fable 등)를 상태바에 표시할지 (기본 켜짐)
    private var showModels: Bool {
        get { defaults.object(forKey: "showModels") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showModels") }
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
        guard Date() >= nextAllowedFetch else { return }
        Task { @MainActor in
            do {
                usage = try await UsageAPI.fetch()
                lastError = nil
                lastUpdated = Date()
                backoff = 0
            } catch let e as UsageError {
                lastError = e
                if case .rateLimited(let after) = e {
                    backoff = min(600, max(60, backoff * 2))
                    nextAllowedFetch = Date().addingTimeInterval(max(after, backoff))
                }
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

    /// 상태바용 짧은 모델 라벨 (Fable → Fb, 그 외는 앞 두 글자)
    private func shortName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "M" }
        let known = ["Fable": "Fb", "Opus": "Op", "Sonnet": "Sn", "Haiku": "Hk"]
        return known[name] ?? String(name.prefix(2))
    }

    /// 한도별 초기화 날짜·시간 (메뉴 상단에 표시; 상태바 툴팁은 메뉴가 붙어 있어 뜨지 않음)
    private func resetLines() -> [String] {
        var rows: [(String, UsageWindow?)] = [("5h", usage?.five_hour), ("7d", usage?.seven_day)]
        for l in usage?.limits ?? [] where l.kind == "weekly_scoped" {
            rows.append((shortName(l.scope?.model?.display_name), l.window))
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M/d(E) HH:mm"
        return rows.compactMap { tag, w in w?.resetDate.map { "\(tag)  \(f.string(from: $0)) 초기화" } }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        // 기간 라벨은 숫자(12pt)의 절반 크기
        let label = NSFont.systemFont(ofSize: 6, weight: .semibold)

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
        if showModels {
            for l in usage?.limits ?? [] where l.kind == "weekly_scoped" {
                add(shortName(l.scope?.model?.display_name), remaining(l.window))
            }
        }
        // 429는 일시적이고 직전 값이 그대로 유효하므로 ⚠를 띄우지 않음 (메뉴에만 안내)
        if let e = lastError, !e.isRateLimited {
            s.append(NSAttributedString(string: " ⚠", attributes: [.font: font]))
        }
        if pendingUpdate != nil {
            s.append(NSAttributedString(string: " ↑", attributes: [.font: font, .foregroundColor: NSColor.systemBlue]))
        }
        button.attributedTitle = s
    }

    // MARK: 메뉴

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        for line in resetLines() { menu.addItem(info(line)) }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        if let e = lastError {
            menu.addItem(info("⚠ \(e.message)"))
        }
        if let t = lastUpdated {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            menu.addItem(info("마지막 갱신 \(f.string(from: t))"))
        }

        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
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
        modeMenu.addItem(.separator())
        let models = NSMenuItem(title: "모델별 주간 한도 (Fable 등)", action: #selector(toggleModels), keyEquivalent: "")
        models.target = self
        models.state = showModels ? .on : .off
        modeMenu.addItem(models)
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 갱신 주기
        let intItem = NSMenuItem(title: "갱신 주기", action: nil, keyEquivalent: "")
        let intMenu = NSMenu()
        for (label, sec) in [("1분", 60.0), ("2분", 120.0), ("5분", 300.0)] {
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

    @objc private func toggleModels() {
        showModels.toggle()
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

        // 메뉴에서 직접 누른 경우: 메뉴가 닫혀 결과가 안 보이므로 팝업으로 알림
        guard sender != nil else { return }
        if let u = pendingUpdate {
            let notes = u.notes.map { "\n\n\($0)" } ?? ""
            if alert("새 버전 v\(u.version)이 있습니다.\(notes)",
                     detail: "현재 v\(Updater.currentVersion) (\(Updater.currentBuild))",
                     buttons: ["지금 설치", "나중에"]) == .alertFirstButtonReturn {
                installUpdate()
            }
        } else {
            _ = alert(updateStatus == "최신 버전" ? "최신 버전입니다." : "업데이트를 확인하지 못했습니다.",
                      detail: updateStatus == "최신 버전"
                          ? "v\(Updater.currentVersion) (\(Updater.currentBuild))"
                          : (updateStatus ?? ""),
                      buttons: ["확인"])
        }
    }

    @discardableResult
    private func alert(_ title: String, detail: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)  // 메뉴바 전용 앱이라 앞으로 가져와야 팝업이 보임
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        buttons.forEach { a.addButton(withTitle: $0) }
        return a.runModal()
    }

    @objc private func installUpdate() {
        guard let u = pendingUpdate else { return }
        do {
            try Updater.install(u)
        } catch let e as UsageError {
            updateStatus = e.message
            rebuildMenu()
            alert("업데이트 설치 실패", detail: e.message, buttons: ["확인"])
        } catch {
            updateStatus = error.localizedDescription
            rebuildMenu()
            alert("업데이트 설치 실패", detail: error.localizedDescription, buttons: ["확인"])
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
