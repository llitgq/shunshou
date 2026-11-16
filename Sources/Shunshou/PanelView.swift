import SwiftUI
import AppKit

// 控制面板 v3（用户 2026-11-14 定格式）：
//   ┌────────────────────────────┐
//   │ 🖐 顺手              [总开关] │
//   ├────────────────────────────┤
//   │ ▭ APP 窗口吸附       [开关]  │ ← 悬停展开：停靠中的 APP 详情（左右侧/状态/召回）
//   ├────────────────────────────┤
//   │ ⏻ 退出                      │
//   └────────────────────────────┘
// 功能行架构：将来加新功能 = 加一行（插件式雏形）

struct PanelView: View {
    @ObservedObject private var engine = Engine.shared
    @State private var snapshot: Engine.Snapshot?
    @State private var featureHover = false

    var body: some View {
        VStack(spacing: 0) {
            head
            Divider().opacity(0.5)
            if let s = snapshot {
                if !s.authorized { authBanner }
                VStack(alignment: .leading, spacing: 0) {
                    featureRow(s)
                    if featureHover { featureDetail(s) }
                }
                // hover 监听挂在整个容器（行+详情）上：只挂行的话，鼠标从行挪进详情的
                // 瞬间行离开 hover → 详情收起 → "召回"永远点不到
                .onHover { h in withAnimation(.easeOut(duration: 0.16)) { featureHover = h } }
                Spacer(minLength: 0)
                quitRow
            } else {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
        }
        .frame(width: 320, height: 300)
        .background(.ultraThinMaterial)
        .onAppear { snapshot = engine.panelSnapshot() }
        .onChange(of: engine.cfgVersion) { _ in snapshot = engine.panelSnapshot() }
        .onChange(of: engine.docked) { _ in snapshot = engine.panelSnapshot() }
    }

    // ── 头部：顺手 + 总开关 ──
    private var head: some View {
        HStack(spacing: 9) {
            Text("🖖").font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text("顺手").font(.system(size: 13, weight: .semibold))
                Text(snapshot?.enabled == true ? "窗口工具 · 一个开关的事" : "已停用")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: masterBinding).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var masterBinding: Binding<Bool> {
        Binding(get: { snapshot?.enabled ?? false },
                set: { _ in engine.toggleMaster(); snapshot = engine.panelSnapshot() })
    }
    /// 窗口吸附组件的独立开关（与总开关分权：总开关管整个产品，这里只管吸附）
    private var featureBinding: Binding<Bool> {
        Binding(get: { snapshot?.docking ?? false },
                set: { _ in engine.toggleDocking(); snapshot = engine.panelSnapshot() })
    }

    private var authBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("需要辅助功能权限").font(.system(size: 11.5))
            Spacer()
            Button("去授权") {
                NSWorkspace.shared.open(URL(fileURLWithPath:
                    "/System/Applications/System Settings.app"))
                engine.refreshAuth()
            }.buttonStyle(.link).font(.system(size: 11.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
    }

    // ── 功能行：APP 窗口吸附 + 开关（悬停展开详情） ──
    private func featureRow(_ s: Engine.Snapshot) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.portrait.right.and.rectangle")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 18)
            Text("贴边收纳").font(.system(size: 12.5, weight: .medium))
            if !s.docked.isEmpty {
                Text("\(s.docked.count)")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.75)))
            }
            Spacer(minLength: 8)
            Toggle("", isOn: featureBinding).toggleStyle(.switch).controlSize(.regular).labelsHidden()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 7).fill(featureHover ? Color.primary.opacity(0.05) : .clear))
        .opacity(s.docking ? 1 : 0.45)
    }

    // ── 悬停展开：停靠中的 APP 详情 ──
    private func featureDetail(_ s: Engine.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if s.docked.isEmpty {
                Text("当前没有停靠窗口 · 拖任意窗口到屏幕左/右边缘松手即收纳")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
            } else {
                ForEach(s.docked) { e in
                    HStack(spacing: 8) {
                        Dot(name: e.app)
                        Text(e.app).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        statePill(e)
                        Button("召回") { engine.recall(e.id) }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .font(.system(size: 10.5))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
                Button {
                    engine.recallAll(); snapshot = engine.panelSnapshot()
                } label: {
                    Text("全部召回").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 12).padding(.vertical, 3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
        .padding(.horizontal, 5)
    }

    private func statePill(_ e: DockedEntry) -> some View {
        let (text, color): (String, Color) = {
            switch e.state {
            case .inView, .slideIn: return ("已滑入", .green)
            case .out: return (e.side == .right ? "右侧屏外" : "左侧屏外", .orange)
            case .animating: return ("…", .secondary)
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(color)
    }

    // ── 退出 ──
    private var quitRow: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            Button {
                engine.shutdown()
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "power").font(.system(size: 10))
                    Text("退出").font(.system(size: 12.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }
}

/// 首字色点：名字 hash 出稳定色相
struct Dot: View {
    let name: String
    var body: some View {
        let hue = name.unicodeScalars.reduce(0) { ($0 * 31 &+ numericCast($1.value)) & 0xFFFF }
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(Color(hue: Double(hue % 360) / 360, saturation: 0.52, brightness: 0.62))
            .frame(width: 8, height: 8)
    }
}
