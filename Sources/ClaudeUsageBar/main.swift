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

    var isLoginProblem: Bool {
        switch self {
        case .noCredentials, .unauthorized: return true
        default: return false
        }
    }
}

// MARK: - 자격증명 (macOS 키체인의 Claude Code 토큰 사용)

enum Credentials {
    static func accessToken() throws -> String {
        guard let token = try oauth()["accessToken"] as? String else { throw UsageError.noCredentials }
        return token
    }

    /// 키체인 로그인 정보의 요금제 표시용 이름 (예: Max 20x, Pro)
    static func planName() -> String? {
        guard let o = try? oauth() else { return nil }
        let tier = o["rateLimitTier"] as? String ?? ""
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        return (o["subscriptionType"] as? String)?.capitalized
    }

    private static func oauth() throws -> [String: Any] {
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
            let oauth = json["claudeAiOauth"] as? [String: Any]
        else { throw UsageError.noCredentials }
        return oauth
    }
}

struct Profile: Decodable {
    struct Account: Decodable {
        let display_name: String?
        let email: String?
    }
    let account: Account
}

// MARK: - API

enum UsageAPI {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// 로그인된 계정 정보 (이름·이메일)
    static func profile() async throws -> Profile {
        try await get(profileURL)
    }

    static func fetch() async throws -> UsageResponse {
        try await get(url)
    }

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
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
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - ChatGPT (Codex CLI 로그인 정보로 사용량 조회)

struct ChatGPTUsage: Decodable {
    struct Window: Decodable {
        let used_percent: Double?
        let reset_at: Double?

        var window: UsageWindow {
            UsageWindow(utilization: used_percent,
                        resets_at: reset_at.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) })
        }
    }
    struct RateLimit: Decodable {
        let primary_window: Window?    // 5시간
        let secondary_window: Window?  // 주간
    }
    let plan_type: String?
    let rate_limit: RateLimit?

    var fiveHour: UsageWindow? { rate_limit?.primary_window?.window }
    var weekly: UsageWindow? { rate_limit?.secondary_window?.window }
    var planName: String? { plan_type.map { "ChatGPT \($0.capitalized)" } }
}

enum ChatGPTAPI {
    static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Codex CLI가 저장한 로그인 정보 (~/.codex/auth.json)
    static var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: authFile.path) }

    static func fetch() async throws -> ChatGPTUsage {
        guard
            let data = try? Data(contentsOf: authFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = json["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String
        else { throw UsageError.noCredentials }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw UsageError.unauthorized }
        if code == 429 { throw UsageError.rateLimited(retryAfter: 0) }
        guard code == 200 else { throw UsageError.http(code) }
        return try JSONDecoder().decode(ChatGPTUsage.self, from: body)
    }
}

/// 서비스별 구분 색상
enum ServiceColor {
    static let claude = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
    static let chatGPT = NSColor(srgbRed: 0x10 / 255.0, green: 0xA3 / 255.0, blue: 0x7F / 255.0, alpha: 1)
    static let gemini = NSColor(srgbRed: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0, alpha: 1)
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
    private var profile: Profile?
    private var loginProcess: Process?
    private var gpt: ChatGPTUsage?
    private var gptError: UsageError?
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
    /// ChatGPT(Codex) 사용량을 상태바에 표시할지 (Codex 로그인이 있으면 기본 켜짐)
    /// 압축 표시 (메뉴바 공간이 부족해 아이콘이 밀려나지 않도록 기본 켜짐)
    private var compact: Bool {
        get { defaults.object(forKey: "compact") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "compact") }
    }
    private var showGPT: Bool {
        get { defaults.object(forKey: "showGPT") as? Bool ?? ChatGPTAPI.isInstalled }
        set { defaults.set(newValue, forKey: "showGPT") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 예전 30초 설정이 남아 있으면 지워서 기본 1분으로 (Claude·ChatGPT 모두 같은 주기로 갱신)
        if defaults.object(forKey: "interval") != nil, defaults.double(forKey: "interval") < 60 {
            defaults.removeObject(forKey: "interval")
        }
        statusItem.button?.title = "Claude …"
        rebuildMenu()
        refresh()
        scheduleTimer()
        checkForUpdates(nil)
        checkLogin(nil)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(nil)
            self?.checkLogin(nil)
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
        refreshGPT()
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

    /// ChatGPT 사용량 (Claude와 별개로 실패해도 Claude 표시는 그대로)
    private func refreshGPT() {
        guard showGPT, ChatGPTAPI.isInstalled else { return }
        Task { @MainActor in
            do {
                gpt = try await ChatGPTAPI.fetch()
                gptError = nil
            } catch let e as UsageError {
                gptError = e
            } catch {
                gptError = .other(error.localizedDescription)
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

    /// 상태바용 짧은 모델 라벨 (Fable → Fb, 그 외는 앞 두 글자)
    private func shortName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "M" }
        let known = ["Fable": "Fb", "Opus": "Op", "Sonnet": "Sn", "Haiku": "Hk"]
        return known[name] ?? String(name.prefix(2))
    }

    /// 한도별 초기화 날짜·시간 (메뉴 상단에 표시; 상태바 툴팁은 메뉴가 붙어 있어 뜨지 않음)
    private func resetLines() -> [String] {
        var rows: [(String, UsageWindow?)] = [("Claude 5h", usage?.five_hour), ("Claude 7d", usage?.seven_day)]
        for l in usage?.limits ?? [] where l.kind == "weekly_scoped" {
            rows.append(("Claude \(shortName(l.scope?.model?.display_name))", l.window))
        }
        if showGPT, let gpt {
            rows += [("GPT 5h", gpt.fiveHour), ("GPT 7d", gpt.weekly)]
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M/d(E) HH:mm"
        return rows.compactMap { tag, w in w?.resetDate.map { "\(tag)  \(f.string(from: $0)) 초기화" } }
    }

    /// 상태바에 그릴 한 칸: 위에 작은 라벨(5h/7d), 아래에 숫자. 라벨이 없으면 한 줄로 가운데
    private struct Segment {
        var label: String?
        var text: String
        var color: NSColor
        var gap: CGFloat  // 앞 칸과의 간격
        var logo: Logo? = nil
        var group: Int? = nil  // 같은 서비스 묶음 (배경을 함께 칠함)
        var low = false        // 남은 비율 10% 이하 → 숫자 뒤에 빨간 배경
    }

    /// 상태바 크기·간격 (압축 표시는 % 기호를 빼고 글자·로고·간격을 줄임)
    struct BarLayout {
        var number: CGFloat, label: CGFloat, logo: CGFloat
        var itemGap: CGFloat, logoGap: CGFloat, groupGap: CGFloat, pad: CGFloat
        var lineGap: CGFloat  // 라벨과 숫자 사이 세로 간격
        var percent: Bool

        static let regular = BarLayout(number: 11, label: 7.5, logo: 11,
                                       itemGap: 7, logoGap: 4, groupGap: 14, pad: 4, lineGap: 2, percent: true)
        static let compact = BarLayout(number: 10, label: 6.5, logo: 9,
                                       itemGap: 4, logoGap: 3, groupGap: 8, pad: 3, lineGap: 1.5, percent: false)
    }

    /// 서비스 구분용 로고 모양 (공식 이미지 대신 코드로 그린 단순 도형)
    enum Logo {
        case claude, chatGPT, gemini

        func draw(at origin: NSPoint, size: CGFloat, color: NSColor) {
            let r = size / 2
            let c = NSPoint(x: origin.x + r, y: origin.y + r)
            color.set()
            switch self {
            case .claude:
                // 방사형 불꽃: 가운데에서 뻗는 짧은 선 10개
                let p = NSBezierPath()
                p.lineWidth = 1.6
                p.lineCapStyle = .round
                for i in 0..<10 {
                    let a = CGFloat(i) * .pi / 5 + .pi / 10
                    p.move(to: NSPoint(x: c.x + cos(a) * 1.2, y: c.y + sin(a) * 1.2))
                    p.line(to: NSPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                }
                p.stroke()
            case .chatGPT:
                // 육각형 매듭 느낌: 바깥 육각형 + 안쪽 회전 육각형
                for (radius, offset) in [(r - 0.8, 0.0), (r - 3.2, CGFloat.pi / 6)] {
                    let p = NSBezierPath()
                    p.lineWidth = 1.4
                    p.lineJoinStyle = .round
                    for i in 0...6 {
                        let a = CGFloat(i) * .pi / 3 + offset + .pi / 2
                        let pt = NSPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
                        i == 0 ? p.move(to: pt) : p.line(to: pt)
                    }
                    p.stroke()
                }
            case .gemini:
                // 네 꼭짓점 반짝임 별 (변이 안쪽으로 휜 모양)
                let p = NSBezierPath()
                let tips = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y),
                            NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
                p.move(to: tips[0])
                for i in 1...4 {
                    p.curve(to: tips[i % 4], controlPoint1: c, controlPoint2: c)
                }
                p.close()
                p.fill()
            }
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }

        let claudeMissing = usage == nil && lastError != nil
        let layout = compact ? BarLayout.compact : BarLayout.regular
        var segs: [Segment] = []
        // 다음 숫자 칸 앞 간격: 로고 바로 뒤는 좁게
        var nextGap = layout.itemGap
        var group = -1
        func add(_ tag: String, _ p: Int?, _ service: NSColor) {
            segs.append(Segment(label: tag, text: p.map { layout.percent ? "\($0)%" : "\($0)" } ?? "–",
                                color: service, gap: segs.isEmpty ? 0 : nextGap, group: group,
                                low: (p ?? 100) <= 10))
            nextGap = layout.itemGap
        }
        func logo(_ l: Logo, _ service: NSColor) {
            group += 1
            segs.append(Segment(label: nil, text: "", color: service, gap: segs.isEmpty ? 0 : layout.groupGap,
                                logo: l, group: group))
            nextGap = layout.logoGap
        }
        // Claude
        logo(.claude, ServiceColor.claude)
        if claudeMissing {
            segs.append(Segment(label: nil, text: "⚠", color: ServiceColor.claude, gap: layout.logoGap, group: group))
        } else {
            if mode != .weekly { add("5h", remaining(usage?.five_hour), ServiceColor.claude) }
            if mode != .fiveHour { add("7d", remaining(usage?.seven_day), ServiceColor.claude) }
        }
        if showModels {
            for l in usage?.limits ?? [] where l.kind == "weekly_scoped" {
                add(shortName(l.scope?.model?.display_name), remaining(l.window), ServiceColor.claude)
            }
        }
        // Claude 오류 ⚠는 Claude 묶음 안에 (429는 일시적이고 직전 값이 유효하므로 띄우지 않음)
        if !claudeMissing, let e = lastError, !e.isRateLimited {
            segs.append(Segment(label: nil, text: "⚠", color: ServiceColor.claude, gap: layout.logoGap, group: group))
        }
        // ChatGPT
        if showGPT, let gpt {
            logo(.chatGPT, ServiceColor.chatGPT)
            if mode != .weekly { add("5h", remaining(gpt.fiveHour), ServiceColor.chatGPT) }
            if mode != .fiveHour { add("7d", remaining(gpt.weekly), ServiceColor.chatGPT) }
        }
        // 업데이트 표시는 모든 묶음 뒤에만
        if pendingUpdate != nil {
            segs.append(Segment(label: nil, text: "↑", color: .systemBlue, gap: 5))
        }

        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.image = stackedImage(segs, layout)
        button.imagePosition = .imageOnly
    }

    /// 라벨을 숫자 위에 쌓아 그린 상태바 이미지 (그리는 시점의 다크/라이트 모드 색을 따름)
    private func stackedImage(_ segs: [Segment], _ layout: BarLayout) -> NSImage {
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: layout.number, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: layout.label, weight: .medium)
        let height = NSStatusBar.system.thickness

        func size(_ s: String, _ f: NSFont) -> NSSize { (s as NSString).size(withAttributes: [.font: f]) }
        let widths = segs.map { seg in
            seg.logo != nil ? layout.logo
                : ceil(max(size(seg.text, numberFont).width, seg.label.map { size($0, labelFont).width } ?? 0))
        }
        // 묶음 배경이 잘리지 않게 양 끝 여백
        let pad = layout.pad
        let total = zip(segs, widths).reduce(0) { $0 + $1.0.gap + $1.1 } + pad * 2

        return NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            // 1) 서비스 묶음 배경: 로고 색을 옅게 깐 둥근 사각형
            var bx = pad
            var spans: [Int: (from: CGFloat, to: CGFloat, color: NSColor)] = [:]
            for (seg, w) in zip(segs, widths) {
                bx += seg.gap
                if let g = seg.group {
                    let c = seg.logo != nil ? seg.color : spans[g]?.color ?? seg.color
                    spans[g] = (spans[g]?.from ?? bx, bx + w, c)
                }
                bx += w
            }
            for span in spans.values {
                let rect = NSRect(x: span.from - pad, y: 1, width: span.to - span.from + pad * 2, height: height - 2)
                // 흰 글씨가 다크·라이트 메뉴바 모두에서 읽히도록 진하게
                span.color.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }

            // 2) 로고·라벨·숫자 (배경 안은 모두 흰색)
            var x = pad
            for (seg, w) in zip(segs, widths) {
                x += seg.gap
                let num = size(seg.text, numberFont)
                let ink: NSColor = seg.group != nil ? .white : seg.color
                if let logo = seg.logo {
                    logo.draw(at: NSPoint(x: x, y: (height - layout.logo) / 2), size: layout.logo, color: ink)
                } else if let label = seg.label {
                    // 아래: 숫자, 위: 라벨. 글꼴 상자 대신 실제 글자 높이(capHeight)로 붙여 쌓고 세로 가운데 정렬
                    let lab = size(label, labelFont)
                    let stack = numberFont.capHeight + layout.lineGap + labelFont.capHeight
                    let numBase = ((height - stack) / 2).rounded()
                    let labBase = numBase + numberFont.capHeight + layout.lineGap
                    if seg.low {
                        NSColor.systemRed.setFill()
                        // 위쪽 여백은 줄 간격보다 작게 해서 라벨과 겹치지 않게
                        NSBezierPath(roundedRect: NSRect(x: x - 2, y: numBase - 1.5, width: w + 4,
                                                         height: numberFont.capHeight + 1.5 + layout.lineGap * 0.5),
                                     xRadius: 3, yRadius: 3).fill()
                    }
                    (seg.text as NSString).draw(at: NSPoint(x: x + (w - num.width) / 2, y: numBase + numberFont.descender),
                                                withAttributes: [.font: numberFont, .foregroundColor: ink])
                    (label as NSString).draw(at: NSPoint(x: x + (w - lab.width) / 2, y: labBase + labelFont.descender),
                                             withAttributes: [.font: labelFont, .foregroundColor: ink.withAlphaComponent(0.85)])
                } else {
                    (seg.text as NSString).draw(at: NSPoint(x: x + (w - num.width) / 2, y: (height - num.height) / 2),
                                                withAttributes: [.font: numberFont, .foregroundColor: seg.color])
                }
                x += w
            }
            return true
        }
    }

    // MARK: 메뉴

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // 로그인 상태
        switch lastError {
        case .noCredentials?:
            menu.addItem(info("⚠ 로그인 안 됨"))
            menu.addItem(info("   아래 \"브라우저로 로그인…\"을 눌러 주세요"))
        case .unauthorized?:
            menu.addItem(info("⚠ 로그인 만료"))
            menu.addItem(info("   Claude Code를 한 번 실행하면 갱신됩니다"))
        default:
            if let a = profile?.account {
                let name = a.display_name ?? a.email ?? "로그인됨"
                let plan = Credentials.planName().map { " · \($0)" } ?? ""
                menu.addItem(info("✓ \(name)\(plan)"))
                if let email = a.email, email != name { menu.addItem(info("   \(email)")) }
            }
        }
        // ChatGPT 로그인 상태 (Codex)
        if showGPT {
            switch gptError {
            case .noCredentials?: menu.addItem(info("⚠ ChatGPT: Codex 로그인 필요 (codex login)"))
            case .unauthorized?: menu.addItem(info("⚠ ChatGPT: 로그인 만료 — Codex를 한 번 실행해 주세요"))
            case .some(let e) where !e.isRateLimited: menu.addItem(info("⚠ ChatGPT: \(e.message)"))
            default:
                if let plan = gpt?.planName { menu.addItem(info("✓ \(plan) (Codex)")) }
            }
        }
        let loginCheck = NSMenuItem(title: "로그인 확인", action: #selector(checkLogin(_:)), keyEquivalent: "l")
        loginCheck.target = self
        menu.addItem(loginCheck)
        if loginProcess != nil {
            menu.addItem(info("브라우저에서 로그인 진행 중…"))
        } else {
            let browser = NSMenuItem(title: "브라우저로 로그인…", action: #selector(loginWithBrowser), keyEquivalent: "")
            browser.target = self
            menu.addItem(browser)
        }
        menu.addItem(.separator())

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
        let gptItem = NSMenuItem(title: "ChatGPT 사용량 (초록)", action: #selector(toggleGPT), keyEquivalent: "")
        gptItem.target = self
        gptItem.state = showGPT ? .on : .off
        modeMenu.addItem(gptItem)
        modeMenu.addItem(.separator())
        let compactItem = NSMenuItem(title: "압축 표시 (폭 줄이기)", action: #selector(toggleCompact), keyEquivalent: "")
        compactItem.target = self
        compactItem.state = compact ? .on : .off
        modeMenu.addItem(compactItem)
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

    @objc private func toggleCompact() {
        compact.toggle()
        updateTitle()
        rebuildMenu()
    }

    @objc private func toggleGPT() {
        showGPT.toggle()
        if showGPT { refreshGPT() }
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

    /// Claude Code CLI 경로 (GUI 앱은 셸 PATH를 못 받으므로 흔한 설치 위치 → 로그인 셸 순으로 찾음)
    private func claudeCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.local/share/node/current/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// `claude auth login`으로 브라우저 로그인 → 키체인 갱신 → 계정·사용량 다시 확인
    @objc private func loginWithBrowser() {
        guard loginProcess == nil else { return }
        guard let cli = claudeCLI() else {
            alert("Claude Code를 찾을 수 없습니다.",
                  detail: "브라우저 로그인은 Claude Code(claude)로 진행됩니다. Claude Code를 먼저 설치해 주세요.",
                  buttons: ["확인"])
            return
        }
        if profile != nil,
           alert("다른 계정으로 로그인할까요?",
                 detail: "Claude Code의 로그인도 함께 바뀝니다.",
                 buttons: ["브라우저로 로그인", "취소"]) != .alertFirstButtonReturn {
            return
        }

        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeUsageBar-login.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["auth", "login", "--claudeai"]
        p.standardInput = FileHandle.nullDevice
        if let h = try? FileHandle(forWritingTo: log) {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loginProcess = nil
                if proc.terminationStatus == 0 {
                    self.lastError = nil
                    self.nextAllowedFetch = .distantPast
                    self.checkLogin(self)  // 결과 팝업 + 사용량 갱신
                    self.refresh()
                } else {
                    let tail = (try? String(contentsOf: log, encoding: .utf8))?
                        .split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
                    self.rebuildMenu()
                    self.alert("브라우저 로그인에 실패했습니다.", detail: tail, buttons: ["확인"])
                }
            }
        }
        do {
            try p.run()
            loginProcess = p
            rebuildMenu()
        } catch {
            alert("브라우저 로그인을 시작하지 못했습니다.", detail: error.localizedDescription, buttons: ["확인"])
        }
    }

    /// 로그인 상태 확인 (sender가 nil이면 조용히, 메뉴에서 누르면 팝업으로 결과 안내)
    @objc private func checkLogin(_ sender: Any?) {
        Task { @MainActor in
            var failure: UsageError?
            do {
                profile = try await UsageAPI.profile()
                // 로그인 문제였다면 해소됐으니 사용량도 바로 다시 가져옴
                if lastError?.isLoginProblem == true {
                    lastError = nil
                    refresh()
                }
            } catch let e as UsageError {
                failure = e
                if case .rateLimited = e {} else { profile = nil; lastError = e }
            } catch {
                failure = .other(error.localizedDescription)
            }
            updateTitle()
            rebuildMenu()

            guard sender != nil else { return }
            if let a = profile?.account, failure == nil {
                let plan = Credentials.planName().map { "\n요금제: \($0)" } ?? ""
                alert("로그인되어 있습니다.",
                      detail: "\(a.display_name ?? "")\n\(a.email ?? "")\(plan)",
                      buttons: ["확인"])
            } else {
                switch failure {
                case .noCredentials?:
                    alert("로그인되어 있지 않습니다.",
                          detail: "메뉴의 \"브라우저로 로그인…\"을 눌러 로그인해 주세요.", buttons: ["확인"])
                case .unauthorized?:
                    alert("로그인이 만료되었습니다.",
                          detail: "Claude Code를 한 번 실행하면 자동으로 갱신됩니다.\n갱신되지 않으면 메뉴의 \"브라우저로 로그인…\"으로 다시 로그인해 주세요.",
                          buttons: ["확인"])
                default:
                    alert("로그인 상태를 확인하지 못했습니다.", detail: failure?.message ?? "", buttons: ["확인"])
                }
            }
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
