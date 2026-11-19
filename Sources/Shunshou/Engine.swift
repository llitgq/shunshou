import Foundation
import AppKit
import ApplicationServices

// 停靠引擎 v2：左右双边 / 贴边吸附 / 拖出自动解除 / 单开关（白名单退役）
//
// 交互模型（2026-11-14 用户拍板）：
//   普通窗口 → 拖到左/右缘贴边（≤25px 或越过）松手 → 停靠，滑出屏外留 10px 把手
//   停靠窗口 → 鼠标碰同侧边缘 → 滑入；鼠标离开 1.5s → 滑回屏外
//   停靠窗口 → 被拖到非贴边位置松手 → 自动解除停靠，恢复普通窗口（拖到另一侧贴边=换边停靠）
//   拖拽检测：mouseDown 快照全部可见窗口位置 + mouseUp diff（Hammerspoon 版验证过的通路）

enum DockSide {
    case left, right
}

enum DockState: Equatable {
    case animating, out, slideIn, inView
}

struct DockedEntry: Identifiable, Equatable {
    let id: CGWindowID            // 系统稳定窗口标识（AXUIElement 每次枚举都是新实例，不能当 id）
    let win: AXUIElement
    let app: String
    let pid: Int32                // 收起指示器取 app 图标用
    var side: DockSide
    var state: DockState
}

@MainActor
final class Engine: ObservableObject {

    // 参数
    static let handleW: CGFloat = 24   // 收起后留在屏内的把手宽度；收起指示器图标嵌在其中
    static let hotZone: CGFloat = 4
    // 贴边判定带：必须真正进到把手条以内。若沿用大容差（≥handleW），把窗口贴到
    // 别人把手上（距屏缘=handleW）会被误判贴屏 → 误吸附 → 新把手同位盖住老把手
    static var snapDist: CGFloat { handleW - 4 }
    static let hideDelay: TimeInterval = 1.5
    static let animDur: TimeInterval = 0.30

    static let shared = Engine()

    // ── 面板数据 ──
    @Published var docked: [DockedEntry] = []
    @Published var cfgVersion = 0
    @Published var authorized = AXIsProcessTrusted()
    @Published var running = false

    private var hideTimers: [CGWindowID: Timer] = [:]
    private var animTimers: [CGWindowID: Timer] = [:]
    private var pollTimer: Timer?
    private var dragTap: DragTap?
    private var downSnapshot: [CGWindowID: CGPoint] = [:]

    private var cfg: ConfigStore { ConfigStore.shared }

    var enabled: Bool { cfg.dockingOn }   // 引擎视角：总开关 ∧ 吸附组件开关

    // MARK: 窗口枚举

    struct VisibleWin {
        let cgId: CGWindowID      // 稳定标识：CGWindowList 的 kCGWindowNumber
        let win: AXUIElement
        let app: String
        let pid: Int32
        let frame: CGRect
    }

    nonisolated static func axFrame(_ w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
              let p = pos, let s = size else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt),
              AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    nonisolated static func setOrigin(_ w: AXUIElement, _ pt: CGPoint) {
        var v = pt
        if let val = AXValueCreate(.cgPoint, &v) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, val)
        }
    }

    /// 屏幕上可见、非最小化的常规 app 窗口
    nonisolated static func visibleWindows() -> [VisibleWin] {
        let screenBounds = NSScreen.screens.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
        var out: [VisibleWin] = []
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let cgId = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            let fr = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                            width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard fr.intersects(screenBounds) else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let name = app.localizedName ?? "?"
            let axApp = AXUIElementCreateApplication(pid)
            // 单 app 的 AX 查询最多等 0.25s：防某个无响应 app 把点击处理拖成整机卡顿
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let wins = winsRef as? [AXUIElement] else { continue }
            var usedAx = Set<ObjectIdentifier>()   // 防一个 AX 窗口被多条 CG 记录重复匹配
            for w in wins {
                var minimized: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized)
                if let m = minimized as? Bool, m { continue }
                let axKey = ObjectIdentifier(w)
                if usedAx.contains(axKey) { continue }
                if let wf = axFrame(w), wf.width > 50, wf.height > 50,
                   abs(wf.midX - fr.midX) < 3, abs(wf.midY - fr.midY) < 3 {
                    usedAx.insert(axKey)
                    out.append(VisibleWin(cgId: cgId, win: w, app: name, pid: pid, frame: wf))
                }
            }
        }
        return out.sorted { $0.app < $1.app }
    }

    // MARK: 启动 / 退出

    func start() {
        guard !running else { return }
        running = true
        var firstEventConfirmed = false
        dragTap = DragTap { [weak self] in
            Task { @MainActor in
                if !firstEventConfirmed {
                    firstEventConfirmed = true
                    NSLog("[shunshou] 事件通路确认：已收到真实鼠标点击")
                }
                self?.snapshotDown()
            }
        } onUp: { [weak self] in
            Task { @MainActor in self?.settleSnap() }
        }
        dragTap?.start()
        startPoll()
        NSLog("[shunshou] 引擎已启动（左右贴边 / 拖出自动解除）")
    }

    func shutdown() {
        recallAll()
        dragTap?.stop(); dragTap = nil
        pollTimer?.invalidate(); pollTimer = nil
        hideTimers.values.forEach { $0.invalidate() }; hideTimers = [:]
        docked = []
        LogoHub.shared.removeAll()
        running = false
        NSLog("[shunshou] 已退出：窗口已召回、监听已停")
    }

    // MARK: 拖拽结算（快照 diff）

    private func snapshotDown() {
        guard enabled else { downSnapshot = [:]; return }
        downSnapshot = [:]
        for v in Engine.visibleWindows() {
            downSnapshot[v.cgId] = v.frame.origin
        }
    }

    private func settleSnap() {
        guard enabled, !downSnapshot.isEmpty else { downSnapshot = [:]; return }
        let snap = downSnapshot
        downSnapshot = [:]
        for v in Engine.visibleWindows() {
            let key = v.cgId
            guard let before = snap[key] else { continue }
            let dx = abs(v.frame.origin.x - before.x), dy = abs(v.frame.origin.y - before.y)
            guard dx > 2 || dy > 2 else { continue }
            let fr = v.frame
            let screen = screenContaining(fr)
            let nearRight = (screen.maxX - fr.maxX) <= Engine.snapDist && fr.maxX > screen.midX
            let nearLeft = (fr.minX - screen.minX) <= Engine.snapDist && fr.minX < screen.midX

            if let idx = docked.firstIndex(where: { $0.id == key }) {
                // ── 已停靠窗口的拖动结算：贴边（任一侧）= 保持/换边停靠；非贴边 = 自动解除 ──
                if animTimers[key] != nil { continue }
                if nearRight || nearLeft {
                    let side: DockSide = nearRight ? .right : .left
                    docked[idx].side = side
                    docked[idx].state = .animating
                    slideOut(key, to: side)
                    NSLog("[shunshou] %@ 换边/换位停靠（%@）", v.app, side == .right ? "右" : "左")
                } else {
                    cancelTimers(key)
                    docked.removeAll { $0.id == key }
                    LogoHub.shared.remove(key)
                    NSLog("[shunshou] %@ 被拖离边缘，自动解除收纳", v.app)
                }
                continue
            }

            // ── 普通窗口：贴边即停靠 ──
            if nearRight {
                dock(v, side: .right)
            } else if nearLeft {
                dock(v, side: .left)
            }
        }
    }

    private func screenContaining(_ fr: CGRect) -> CGRect {
        NSScreen.screens.first { $0.frame.intersects(fr) }?.frame
            ?? NSScreen.main?.frame ?? .infinite
    }

    // MARK: 停靠 / 滑入 / 滑回 / 召回

    private func outX(for side: DockSide, frame fr: CGRect, screen: CGRect) -> CGFloat {
        side == .right ? screen.maxX - Engine.handleW      // 右侧留把手
                       : screen.minX - fr.width + Engine.handleW  // 左侧留把手
    }

    private func inX(for side: DockSide, frame fr: CGRect, screen: CGRect) -> CGFloat {
        side == .right ? screen.maxX - fr.width : screen.minX
    }

    func dock(_ v: VisibleWin, side: DockSide) {
        let key = v.cgId
        guard !docked.contains(where: { $0.id == key }) else { return }
        let screen = screenContaining(v.frame)
        let target = CGPoint(x: outX(for: side, frame: v.frame, screen: screen), y: v.frame.origin.y)
        docked.append(DockedEntry(id: key, win: v.win, app: v.app, pid: v.pid, side: side, state: .animating))
        animate(key, v.win, from: v.frame.origin, to: target) { [weak self] in
            self?.setState(key, .out)
        }
        NSLog("[shunshou] 已停靠：%@（%@）", v.app, side == .right ? "右" : "左")
    }

    func recallAll() {
        for e in docked { recall(e.id) }
    }

    func recall(_ key: CGWindowID) {
        guard let e = docked.first(where: { $0.id == key }) else { return }
        cancelTimers(key)
        docked.removeAll { $0.id == key }
        LogoHub.shared.remove(key)
        if let fr = Engine.axFrame(e.win) {
            let screen = screenContaining(fr)
            let target = CGPoint(x: inX(for: e.side, frame: fr, screen: screen), y: fr.origin.y)
            animate(key, e.win, from: fr.origin, to: target, completion: nil)
        }
    }

    private func slideIn(_ key: CGWindowID) {
        guard let e = docked.first(where: { $0.id == key }), e.state == .out,
              animTimers[key] == nil, let fr = Engine.axFrame(e.win) else { return }
        cancelHide(key)
        setState(key, .slideIn)
        let screen = screenContaining(fr)
        let target = CGPoint(x: inX(for: e.side, frame: fr, screen: screen), y: fr.origin.y)
        animate(key, e.win, from: fr.origin, to: target) { [weak self] in
            self?.setState(key, .inView)
        }
    }

    private func slideOut(_ key: CGWindowID, to side: DockSide? = nil) {
        guard let e = docked.first(where: { $0.id == key }),
              animTimers[key] == nil, let fr = Engine.axFrame(e.win) else { return }
        if e.state == .out && side == nil { return }
        cancelHide(key)
        setState(key, .animating)
        let useSide = side ?? e.side
        let screen = screenContaining(fr)
        let target = CGPoint(x: outX(for: useSide, frame: fr, screen: screen), y: fr.origin.y)
        animate(key, e.win, from: fr.origin, to: target) { [weak self] in
            self?.setState(key, .out)
        }
    }

    private func setState(_ key: CGWindowID, _ s: DockState) {
        if let i = docked.firstIndex(where: { $0.id == key }) {
            docked[i].state = s
            syncLogo(docked[i])
        }
    }

    /// 收起指示器随状态同步：.out 挂上 app 图标，其余状态隐藏
    private func syncLogo(_ e: DockedEntry) {
        switch e.state {
        case .out:
            guard let fr = Engine.axFrame(e.win) else { return }
            LogoHub.shared.show(e.id,
                                icon: NSRunningApplication(processIdentifier: e.pid)?.icon,
                                side: e.side,
                                winFrameCG: fr,
                                screen: screenContaining(fr))
        default:
            LogoHub.shared.hide(e.id)
        }
    }

    private func cancelTimers(_ key: CGWindowID) {
        animTimers[key]?.invalidate(); animTimers[key] = nil
        cancelHide(key)
    }

    private func cancelHide(_ key: CGWindowID) {
        hideTimers[key]?.invalidate(); hideTimers[key] = nil
    }

    // MARK: 动画（60fps easeOutCubic）

    private func animate(_ key: CGWindowID, _ win: AXUIElement,
                         from: CGPoint, to: CGPoint,
                         completion: (() -> Void)?) {
        animTimers[key]?.invalidate()
        let t0 = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                let k = (Date().timeIntervalSince(t0)) / Engine.animDur
                guard k < 1 else {
                    Engine.setOrigin(win, to)
                    self.animTimers[key]?.invalidate()
                    self.animTimers[key] = nil
                    completion?()
                    return
                }
                let e = 1 - pow(1 - k, 3)
                Engine.setOrigin(win, CGPoint(x: from.x + (to.x - from.x) * e,
                                              y: from.y + (to.y - from.y) * e))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimers[key] = timer
    }

    // MARK: 鼠标轮询：碰同侧边缘滑入 / 离开滑回

    private func startPoll() {
        guard pollTimer == nil else { return }
        pollTimer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkMouse() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func checkMouse() {
        guard enabled else { return }
        // 鼠标位置必须用 CG 全局坐标（主屏左上原点）——与 AX/CGWindow 的 frame 同系。
        // NSEvent.mouseLocation 是 AppKit 坐标（左下原点 y 向上），y 直接与 AX frame 比较
        // 会整屏错位：热区 inBand 判 false → 碰边永不滑入；inView 判 false → 滑入后
        // 1.5s 必滑回（震荡回归），用户抓不到窗口。x 轴两系一致，故只有 y 类判定失灵。
        guard let p = CGEvent(source: nil)?.location else { return }
        for e in docked {
            guard let fr = Engine.axFrame(e.win) else {
                docked.removeAll { $0.id == e.id }
                LogoHub.shared.remove(e.id)
                continue
            }
            let screen = screenContaining(fr)
            let key = e.id
            switch e.state {
            case .out:
                // 热区按窗口自己的 y 区间判定：碰哪个窗口的把手，哪个滑入
                //（同侧多窗口不再齐出；把手在垂直方向重叠的窗口属于物理同位，一起出是合理的）
                let onRight = p.x >= screen.maxX - Engine.hotZone - 1 && p.x <= screen.maxX + 2
                let onLeft = p.x >= screen.minX - 2 && p.x <= screen.minX + Engine.hotZone + 1
                let sideHit = (e.side == .right && onRight) || (e.side == .left && onLeft)
                let inBand = p.y >= fr.minY && p.y <= fr.maxY
                if sideHit && inBand {
                    slideIn(key)
                }
            case .inView:
                // 停靠侧向外扩 60px 缓冲带：鼠标停在边缘热区也算"在窗口附近"，
                // 防止 滑入→鼠标在窗缘外→滑回→又碰热区→再滑入 的震荡
                let xLow = e.side == .left ? fr.minX - 60 : fr.minX
                let xHigh = e.side == .right ? fr.maxX + 60 : fr.maxX
                let inWin = p.x >= xLow && p.x <= xHigh && p.y >= fr.minY && p.y <= fr.maxY
                if inWin {
                    cancelHide(key)
                } else if hideTimers[key] == nil {
                    hideTimers[key] = Timer.scheduledTimer(withTimeInterval: Engine.hideDelay, repeats: false) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.hideTimers[key] = nil
                            self?.slideOut(key)
                        }
                    }
                }
            default: break
            }
        }
    }

    // MARK: 面板

    struct Snapshot {
        var enabled: Bool        // 总开关
        var docking: Bool        // 窗口吸附组件开关
        var docked: [DockedEntry]
        var authorized: Bool
    }

    func panelSnapshot() -> Snapshot {
        Snapshot(enabled: cfg.cfg.enabled, docking: cfg.dockingOn,
                 docked: docked, authorized: authorized)
    }

    func toggleMaster() { cfg.toggleMaster(); cfgVersion += 1 }
    func toggleDocking() { cfg.toggleDocking(); cfgVersion += 1 }
    func refreshAuth() { authorized = AXIsProcessTrusted() }
}
