import AppKit

// 顺手 Handy（工程名 Shunshou）· macOS 菜单栏贴边收纳
// 入口：accessory 模式（不占 Dock），跑 AppKit 主循环

let app = NSApplication.shared
let delegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
MainActor.assumeIsolated {
    app.setActivationPolicy(.accessory)
}
app.run()
