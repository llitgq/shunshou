import Foundation
import CoreGraphics

// 拖拽检测：CGEvent tap 监听左键按下/抬起（回调线程 → 派发主线程）
// 策略与 Hammerspoon 验证版一致：按下快照、抬起 diff 结算

final class DragTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let onDown: () -> Void
    private let onUp: () -> Void

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.onDown = onDown
        self.onUp = onUp
    }

    func start() {
        guard port == nil else { return }
        var mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        mask |= (1 << CGEventType.tapDisabledByTimeout.rawValue)   // 超时禁用通知也要能收到
        let callback: CGEventTapCallBack = { _, type, event, info in
            // CGEventTapCallBack 的 info 指向 DragTap 实例
            let tap = Unmanaged<DragTap>.fromOpaque(info!).takeUnretainedValue()
            // 只读监听：回调返回值不生效，事件永远放行，不可能吞掉系统点击
            if type == .leftMouseDown { tap.onDown() } else if type == .leftMouseUp { tap.onUp() }
            // 主线程卡顿超时会让系统禁用 tap：收到禁用通知时自动重新启用
            if type == .tapDisabledByTimeout, let port = tap.port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .listenOnly,          // ← 只读！defaultTap+返回nil会吞掉全系统左键事件（事故根源）
                                        eventsOfInterest: CGEventMask(mask),
                                        callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("[shunshou] 事件 tap 创建失败（检查辅助功能权限）")
            return
        }
        port = p
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
    }

    func stop() {
        if let p = port { CFMachPortInvalidate(p) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        port = nil; source = nil
    }
}
