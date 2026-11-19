import AppKit

// 收起指示器：收起窗口把手顶端悬浮该 app 图标——"是哪个 app 收在边上"一眼可辨
// 纯视觉提示：鼠标穿透、不抢焦点；只在状态切换时重摆，不动时零开销
@MainActor
final class LogoHub {
    static let shared = LogoHub()

    /// 图标实际尺寸：可见部分≈60%（右边探出屏幕外被裁），可见宽度与把手宽对齐
    static let size: CGFloat = 40
    /// 图标顶边相对收起窗口顶边的下移量
    static let topGap: CGFloat = 12

    private var panels: [CGWindowID: NSPanel] = [:]

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true   // 点击穿透到下面的窗口本体（热区滑入靠鼠标位置轮询，不受遮挡影响）
        p.level = .floating
        // contentView 必须在这里就位：NSPanel 创建时自带非 nil 的空 contentView，
        // 想靠"contentView == nil"惰性创建永远不会触发 → 透明空壳（v7 首测无图标的根因）
        // （发光条尝试已撤：layer 光晕在透明浮窗上不出效果，用户拍板不要）
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        p.contentView = iv
        return p
    }

    /// fr 为 AX/CG 坐标（主屏左上原点）；NSWindow.setFrame 是 AppKit 坐标（左下原点），y 须翻转。
    /// 图标贴停靠侧屏缘、顶边对齐窗口顶边（把手的顶端）。局限：多屏纵向排列时 y 翻算未做逐屏修正。
    func show(_ key: CGWindowID, icon: NSImage?, side: DockSide, winFrameCG fr: CGRect, screen: CGRect) {
        let panel = panels[key] ?? makePanel()
        panels[key] = panel
        (panel.contentView as? NSImageView)?.image = icon
        let main = NSScreen.screens.first?.frame ?? .zero
        let w = Self.size
        let topAppKitY = main.minY + main.maxY - fr.minY   // 窗口顶边的 AppKit y
        // 可见宽度 = 把手宽：右侧收纳图标右缘出屏（露左 60%），左侧收纳左缘出屏（露右 60%）
        let x = side == .right ? screen.maxX - Engine.handleW : screen.minX - (w - Engine.handleW)
        let y = topAppKitY - Self.topGap - w               // 图标顶边 = 窗口顶边往下 topGap
        panel.setFrame(NSRect(x: x, y: y, width: w, height: w), display: false)
        panel.orderFrontRegardless()
        NSLog("[shunshou] 收起指示器：app 图标已上屏（%@ 侧，x=%.0f y=%.0f）",
              side == .right ? "右" : "左", x, topAppKitY - w)
    }

    func hide(_ key: CGWindowID) {
        panels[key]?.orderOut(nil)
    }

    func remove(_ key: CGWindowID) {
        panels.removeValue(forKey: key)?.orderOut(nil)
    }

    func removeAll() {
        for (_, p) in panels { p.orderOut(nil) }
        panels = [:]
    }
}
