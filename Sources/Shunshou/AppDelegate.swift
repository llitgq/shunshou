import AppKit
import SwiftUI
import ApplicationServices

// 菜单栏宿主：🖖 状态栏图标 + NSPopover 原生弹出框（系统级锚定、带箭头、点外自动收起）

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Engine.shared.refreshAuth()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🖖"
        item.button?.toolTip = "顺手 Handy · 贴边收纳"
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient          // 点外面自动收起
        pop.animates = true
        pop.contentSize = NSSize(width: 320, height: 300)
        pop.contentViewController = NSHostingController(rootView: PanelView())
        popover = pop

        item.button?.action = #selector(togglePopover(_:))
        item.button?.target = self

        // 权限就绪才启动引擎；面板里也能看状态
        if Engine.shared.authorized {
            Engine.shared.start()
        } else {
            NSLog("[shunshou] 无辅助功能权限，待用户授权（面板可引导）")
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let pop = popover, let button = statusItem?.button else { return }
        Engine.shared.refreshAuth()
        if Engine.shared.authorized, !Engine.shared.running {
            Engine.shared.start()
        }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            // accessory 应用从不激活 → transient popover 永远收不到 resignActive，
            // 点其他 app 面板不收。先激活自己，切走时系统才会自动收起。
            // （注意：activate ≠ makeKey，后者才会触发弹到屏幕中间的重定位 bug）
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
