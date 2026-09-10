// TouchBarAgentStatus — 在 MacBook Touch Bar 上显示 opencode agent 工作状态
// 数据源: ~/.local/share/opencode/opencode.db (SQLite, 只读轮询, WAL 并发安全)
// 显示位置: Touch Bar Control Strip (系统保留区, 任何前台应用下均可见, 私有 API)
//           + macOS 菜单栏镜像 (公开 API, 兜底)
//
// Build: swiftc -O -swift-version 5 main.swift -o TouchBarAgentStatus
// Run:   ./TouchBarAgentStatus          (常驻)
//        ./TouchBarAgentStatus --once   (打印一次状态后退出, 用于自检)

import AppKit
import CoreGraphics
import ObjectiveC
import SQLite3

// SQLITE_TRANSIENT 是 C 宏, Swift 模块不导出, 手动等价定义
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// NSLog 在无终端上下文时不可靠, 直写文件
func dbg(_ msg: String) {
    let path = "/tmp/tbas-debug.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let fh = FileHandle(forWritingAtPath: path) else { return }
    fh.seekToEndOfFile()
    fh.write(Data("\(Date().timeIntervalSince1970) \(msg)\n".utf8))
    try? fh.close()
}

// MARK: - 状态模型

enum StatusKind {
    case idle
    case writing
    case reasoning
    case tool(String)
    case awaiting(String)
    case error(String)
}

struct AgentStatus {
    var kind: StatusKind = .idle
    var title: String = ""
    var directory: String = ""
    var snippet: String = ""
    var lastActivityMs: Double = 0

    var isWorking: Bool {
        switch kind {
        case .idle, .error: return false
        default: return true
        }
    }

    var shortDescription: String {
        switch kind {
        case .idle: return "💤 idle"
        case .writing: return "✍️ writing"
        case .reasoning: return "🧠 thinking"
        case .tool(let t): return "🔧 \(t.uppercased())"
        case .awaiting(let what): return "🔔 awaiting \(what)"
        case .error(let e): return "⚠️ \(e)"
        }
    }

    var longDescription: String {
        switch kind {
        case .idle: return "idle · \(title)"
        case .writing: return "writing · \(title)"
        case .reasoning: return "thinking · \(title)"
        case .tool(let t): return "tool:\(t) · \(title)"
        case .awaiting(let what): return "awaiting \(what) · \(title)"
        case .error(let e): return "error: \(e)"
        }
    }
}

// MARK: - opencode 数据库轮询

final class OpenCodeMonitor {
    private var db: OpaquePointer?
    private let dbPath: String

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func openDB() -> Bool {
        if db != nil { return true }
        guard FileManager.default.fileExists(atPath: dbPath) else { return false }
        var handle: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        sqlite3_busy_timeout(handle, 500)
        db = handle
        return true
    }

    func poll() -> AgentStatus {
        var status = AgentStatus()
        guard openDB() else {
            status.kind = .error("no db")
            return status
        }
        let nowMs = Date().timeIntervalSince1970 * 1000

        // 1. 最近活跃会话
        guard let sess = latestSession() else {
            status.kind = .error("no session")
            return status
        }
        status.title = sess.title.isEmpty ? "opencode" : sess.title
        status.directory = sess.directory
        status.lastActivityMs = sess.updated

        // 2. 该会话最近的 parts, 找等待授权 / running 工具 / 最新活动类型
        let parts = recentParts(sessionID: sess.id)
        for p in parts {
            status.lastActivityMs = max(status.lastActivityMs, p.updated)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(p.data.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            guard type == "tool" else { continue }
            let tool = obj["tool"] as? String ?? ""
            let st = (obj["state"] as? [String: Any])?["status"] as? String ?? ""
            let ageMs = nowMs - p.updated
            // pending 且 30s 无更新 = 参数流式已结束, 正在等待用户授权
            // (流式期间 time_updated 持续刷新不会误报; 30min 上限防进程崩溃残留)
            if st == "pending" && ageMs > 30_000 && ageMs < 1_800_000 {
                status.kind = .awaiting("approval")
                status.snippet = toolSnippet(obj)
                return status
            }
            // question 工具的 running 阶段 = 等待用户回答
            if tool == "question" && st == "running" && ageMs < 1_800_000 {
                status.kind = .awaiting("input")
                return status
            }
            if st == "running" && ageMs < 180_000 {
                status.kind = .tool(tool)
                status.snippet = toolSnippet(obj)
                return status
            }
        }
        // 无 running 工具: 按最近一次 part 类型分级判定宽限期
        // (数据库无写入 ≠ agent 空闲: step-start 后的 prefill/长思考、reasoning 流间歇都会长时间无写入)
        if let last = parts.first,
           let obj = try? JSONSerialization.jsonObject(with: Data(last.data.utf8)) as? [String: Any] {
            let lastType = obj["type"] as? String ?? ""
            var kind = StatusKind.writing
            var graceMs = 10_000.0
            switch lastType {
            case "step-start":  // 一步已开始但尚无产出, 视为 thinking (600s 上限防进程崩溃残留)
                kind = .reasoning
                graceMs = 600_000
            case "reasoning":  // 流式推理中, 宽限 120s 容忍流中间歇
                kind = .reasoning
                graceMs = 120_000
            default:  // text / step-finish 等: 正在输出或回合已结束, 维持 10s
                break
            }
            if nowMs - last.updated < graceMs {
                status.kind = kind
                if case .writing = kind { status.snippet = latestTextSnippet(parts) }
            }
        }
        return status
    }

    // MARK: sqlite 查询 (值在 finalize 前拷贝, 杜绝 use-after-free)

    private func latestSession() -> (id: String, title: String, directory: String, updated: Double)? {
        runQuery("SELECT id, title, directory, time_updated FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC LIMIT 1") { stmt in
            (copyText(stmt, 0), copyText(stmt, 1), copyText(stmt, 2), sqlite3_column_double(stmt, 3))
        }
    }

    private func recentParts(sessionID: String) -> [(data: String, updated: Double)] {
        // 不复用 runQuery: 其 collect 返回非 nil 即提前退出, 只能收集到第一行
        var out: [(data: String, updated: Double)] = []
        guard let db else { return out }
        var stmt: OpaquePointer?
        let sql = "SELECT data, time_updated FROM part WHERE session_id = ?1 ORDER BY time_updated DESC LIMIT 30"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return out }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((copyText(stmt, 0), sqlite3_column_double(stmt, 1)))
        }
        return out
    }

    // 从 part.data 提取简短文字内容 (工具输入 / 最近文本首行)

    private func toolSnippet(_ obj: [String: Any]) -> String {
        guard let state = obj["state"] as? [String: Any],
              let input = state["input"] as? [String: Any] else { return "" }
        for key in ["command", "cmd", "path", "filePath", "url", "pattern", "query", "name"] {
            if let v = input[key] as? String, !v.isEmpty { return v }
        }
        return ""
    }

    private func latestTextSnippet(_ parts: [(data: String, updated: Double)]) -> String {
        for p in parts {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(p.data.utf8)) as? [String: Any],
                  (obj["type"] as? String) == "text",
                  let t = obj["text"] as? String, !t.isEmpty else { continue }
            return t
        }
        return ""
    }

    private func runQuery<T>(_ sql: String, bind: String? = nil, _ collect: (OpaquePointer) -> T?) -> T? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        if let bind {
            sqlite3_bind_text(stmt, 1, bind, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let result = collect(stmt) { return result }
        }
        return nil
    }

    private func copyText(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }
}

// MARK: - UI (菜单栏 + Touch Bar Control Strip)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let touchItem = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier("com.riotsakura.opencode.status"))
    private let touchButton = NSButton(title: "🤖 …", target: nil, action: nil)
    private let trayItem = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier("com.riotsakura.opencode.tray"))
    private let trayButton = NSButton(title: "🤖", target: nil, action: nil)
    private let escItem = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier("com.riotsakura.opencode.esc"))
    private let escButton = NSButton(title: "esc", target: nil, action: nil)
    private var fullTouchBar = NSTouchBar()
    private let monitor: OpenCodeMonitor
    private var timer: Timer?
    private var tick: Int = 0
    private var current = AgentStatus()
    private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private let touchFont = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)

    init(dbPath: String) {
        monitor = OpenCodeMonitor(dbPath: dbPath)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBarItem()
        setupTouchBar()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        onTick()
    }

    private func onTick() {
        tick += 1
        if tick % 4 == 1 {
            current = monitor.poll()
            presentTouchBar()  // 重新断言呈现 (系统可能因切换前台应用等原因收回)
        }
        render()
    }

    private func render() {
        let s = current
        let spinner = spinnerFrames[(tick / 2) % spinnerFrames.count]
        var segments: [String]
        switch s.kind {
        case .idle:
            segments = s.title.isEmpty ? ["💤"] : ["💤", shorten(s.title, 24)]
        case .error(let e):
            segments = ["⚠️", e]
        case .awaiting(let what):
            // 铃铛 1Hz 闪烁, 提醒需要用户操作 (授权 / 回答)
            let bell = (tick / 2) % 2 == 0 ? "🔔" : "🔕"
            segments = ["\(bell) awaiting \(what)"]
            if !s.snippet.isEmpty { segments.append(shorten(s.snippet, 30)) }
        default:
            segments = [s.shortDescription]
            if !s.snippet.isEmpty { segments.append(shorten(s.snippet, 30)) }
            segments.append(spinner)
        }
        setTouchTitle(segments.joined(separator: " · "))
        let trayIcon: String
        switch s.kind {
        case .idle: trayIcon = "💤"
        case .error: trayIcon = "⚠️"
        case .writing: trayIcon = "✍️"
        case .reasoning: trayIcon = "🧠"
        case .tool: trayIcon = "🔧"
        case .awaiting: trayIcon = "🔔"
        }
        trayButton.title = trayIcon
        statusItem.button?.title = s.isWorking ? s.shortDescription : "💤"

        if let menu = statusItem.menu {
            if let item = menu.item(withTag: 100) {
                item.title = s.longDescription
            }
        }
    }

    private func setupMenuBarItem() {
        touchButton.bezelStyle = .rounded
        touchButton.font = touchFont
        touchButton.target = self
        touchButton.action = #selector(refreshNow)
        touchItem.view = touchButton

        let menu = NSMenu()
        let statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        statusLine.tag = 100
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func refreshNow() {
        current = monitor.poll()
        render()
    }

    // Touch Bar 大字号文字 (白色加粗, 覆盖系统默认小字体)

    private func setTouchTitle(_ text: String) {
        touchButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: touchFont,
            .foregroundColor: NSColor.white,
        ])
        // attributedTitle 不会自动触发 intrinsic size 失效, DFR 拿不到新宽度
        // 就会按注入时的初始尺寸渲染 (只剩一个图标) 甚至在展开时丢弃控件
        touchButton.invalidateIntrinsicContentSize()
        touchButton.needsLayout = true
        touchButton.superview?.needsLayout = true
        touchButton.superview?.layoutSubtreeIfNeeded()
    }

    // 压缩为单行并截断到 n 个字符

    private func shorten(_ s: String, _ n: Int) -> String {
        let firstLine = String(s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        let collapsed = firstLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > n else { return trimmed }
        return String(trimmed.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Touch Bar 状态条 (MTMR 同款, 占 App 区域, 保留 Esc/Control Strip)

    private func setupTouchBar() {
        // 1. 常驻托盘按钮 (Control Strip 中的小图标, 点击恢复状态条)
        trayButton.bezelStyle = .rounded
        trayButton.target = self
        trayButton.action = #selector(presentTouchBar)
        trayItem.view = trayButton
        let okTray = addSystemTrayItem(trayItem)
        setTrayPresence(true)

        // 2. 自渲染 esc (App 区域被替换时系统 Esc 不保留)
        escButton.bezelStyle = .rounded
        escButton.target = self
        escButton.action = #selector(postEscape)
        escItem.view = escButton

        // 3. 状态条: [esc] [status]
        fullTouchBar.delegate = self
        fullTouchBar.defaultItemIdentifiers = [escItem.identifier, touchItem.identifier]

        // 4. 呈现 (placement 0 = App 区域, 保留系统 Control Strip; 1 = 全宽接管, 经 TBAS_PLACEMENT 覆盖)
        hideCloseBox()
        let okPresent = presentTouchBar()
        dbg("setupTouchBar tray=\(okTray) present=\(okPresent) placement=\(statusPlacement)")
    }

    private var statusPlacement: Int64 {
        // 0 = App 区域 (保留 Esc 区域语义 + 系统 Control Strip), 1 = 全宽接管
        // 其余值 (2-5) 会让 presentSystemModalTouchBar 永久阻塞, 勿用
        if let s = ProcessInfo.processInfo.environment["TBAS_PLACEMENT"], let v = Int64(s) { return v }
        return 0
    }

    @objc @discardableResult private func presentTouchBar() -> Bool {
        let sel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard let method = class_getClassMethod(NSTouchBar.self, sel) else { return false }
        typealias PresentFn = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, String) -> Void
        let present = unsafeBitCast(method_getImplementation(method), to: PresentFn.self)
        present(NSTouchBar.self, sel, fullTouchBar, statusPlacement, trayItem.identifier.rawValue)
        return true
    }

    private func hideCloseBox() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY),
              let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        typealias Fn = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: Fn.self)(false)
    }

    @objc private func postEscape() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private func addSystemTrayItem(_ item: NSTouchBarItem) -> Bool {
        let sel = NSSelectorFromString("addSystemTrayItem:")
        guard let method = class_getClassMethod(NSTouchBarItem.self, sel) else { return false }
        typealias AddFn = @convention(c) (AnyObject, Selector, NSTouchBarItem) -> Void
        let add = unsafeBitCast(method_getImplementation(method), to: AddFn.self)
        add(NSTouchBarItem.self, sel, item)
        return true
    }

    private func setTrayPresence(_ visible: Bool) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY),
              let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias SetPresenceFn = @convention(c) (CFString, Bool) -> Void
        let setPresence = unsafeBitCast(sym, to: SetPresenceFn.self)
        setPresence(trayItem.identifier.rawValue as CFString, visible)
    }
}

extension AppDelegate: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == escItem.identifier { return escItem }
        guard identifier == touchItem.identifier else { return nil }
        return touchItem
    }
}

// MARK: - main

func defaultDBPath() -> String {
    if let env = ProcessInfo.processInfo.environment["OPENCODE_DB"], !env.isEmpty { return env }
    return NSHomeDirectory() + "/.local/share/opencode/opencode.db"
}

let args = CommandLine.arguments
if args.contains("--once") {
    let m = OpenCodeMonitor(dbPath: defaultDBPath())
    let s = m.poll()
    print(s.longDescription)
    print("db=\(defaultDBPath()) lastActivity=\(Int((Date().timeIntervalSince1970 * 1000 - s.lastActivityMs) / 1000))s ago working=\(s.isWorking)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // 无 Dock 图标
let delegate = AppDelegate(dbPath: defaultDBPath())
app.delegate = delegate
app.run()
