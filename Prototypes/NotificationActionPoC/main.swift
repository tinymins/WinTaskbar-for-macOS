import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

@MainActor
final class Probe: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var status = "先授权，再发送测试通知。仅定位本 PoC 创建的通知，不记录其他消息内容。"
    @Published var events: [String] = []
    @Published var selectedID: String?
    @Published var ids: [String] = []
    private var targets: [String: AXUIElement] = [:]
    private var summaries: [String: String] = [:]

    func note(_ message: String) {
        events.insert("\(Date().formatted(date: .omitted, time: .standard))  \(message)", at: 0)
    }

    func permissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                status = "通知权限：\(allowed)；辅助功能权限：\(trusted)。授权后可再次点击检查。"
            } catch { status = "通知授权错误：\(error.localizedDescription)" }
        }
    }

    func send() {
        let id = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "通知跳转测试 \(ids.count + 1)"
        content.body = "仅测试数据。目标编号：\(id)"
        content.userInfo = ["target": id]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                summaries[id] = "Notification Action PoC, \(content.title), \(content.body)"
                ids.append(id)
                selectedID = id
                note("已发送 \(id)")
            } catch { note("发送失败：\(error.localizedDescription)") }
        }
    }

    func inventory() {
        Task {
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let known = delivered.filter { ids.contains($0.request.identifier) }.map { $0.request.identifier }
            note("系统仍保留本 PoC 通知：\(known.joined(separator: ", "))")
        }
    }

    // Only an exact request UUID or the complete self-generated notification
    // description authorizes a target. Unmatched descriptions are never retained.
    private func isOwnTarget(_ element: AXUIElement, id: String) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success,
           (value as? String)?.contains(id) == true { return true }
        value = nil
        guard let expected = summaries[id],
              AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value) == .success,
              let description = value as? String else { return false }
        return description == expected
    }

    func locate() {
        guard AXIsProcessTrusted() else { status = "缺少辅助功能权限。"; return }
        guard let id = selectedID else { return }
        var matches: [(AXUIElement, AXUIElement)] = []
        var nodes = 0
        var visited = Set<AXUIElement>()
        var incomplete = false
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &result)
            if ![.success, .attributeUnsupported, .noValue].contains(error) { incomplete = true }
            return error == .success ? result : nil
        }
        func visit(_ node: AXUIElement, window: AXUIElement, depth: Int) {
            guard nodes < 600, depth <= 18, ProcessInfo.processInfo.systemUptime < deadline else {
                incomplete = true; return
            }
            guard visited.insert(node).inserted else { return }
            nodes += 1
            if isOwnTarget(node, id: id) { matches.append((node, window)) }
            for child in value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                visit(child, window: window, depth: depth + 1)
            }
        }
        for bundleID in ["com.apple.UserNotificationCenter", "com.apple.notificationcenterui"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.1)
            for window in value(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                visit(window, window: window, depth: 0)
            }
        }
        note("扫描 \(nodes) 个结构节点；本通知精确命中 \(matches.count)；完整：\(!incomplete)")
        guard !incomplete, matches.count == 1, let match = matches.first else { return }
        targets[id] = match.0
        var raw: CFArray?
        let result = AXUIElementCopyActionNames(match.0, &raw)
        note("动作列表状态 \(result.rawValue)：\((raw as? [String] ?? []).joined(separator: ", "))")
    }

    func perform(_ name: String) {
        guard let id = selectedID, let target = targets[id] else { note("尚未定位唯一原通知。"); return }
        guard isOwnTarget(target, id: id) else {
            note("原对象已失效或身份变化，未执行动作。"); return
        }
        var raw: CFArray?
        guard AXUIElementCopyActionNames(target, &raw) == .success,
              (raw as? [String] ?? []).contains(name) else { note("原通知不支持 \(name)。"); return }
        let result = AXUIElementPerformAction(target, name as CFString)
        note("\(name) 返回 \(result.rawValue)；只有收到目标回调才能确认定位成功。")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let requestID = response.notification.request.identifier
        let targetID = response.notification.request.content.userInfo["target"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            guard self.ids.contains(requestID) else { return }
            self.selectedID = requestID
            self.status = "已定位到测试消息：\(targetID ?? "缺失")"
            self.note("收到系统回调：\(action)；请求与目标一致：\(requestID == targetID)")
            NSApp.activate(ignoringOtherApps: true)
        }
        completion()
    }
}

struct ProbeView: View {
    @ObservedObject var probe: Probe
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("系统通知原动作 PoC").font(.title2.bold())
            Text(probe.status).textSelection(.enabled)
            HStack {
                Button("授权 / 检查权限") { probe.permissions() }
                Button("发送测试通知") { probe.send() }
                Button("查询自己的通知") { probe.inventory() }
            }
            Picker("测试目标", selection: $probe.selectedID) {
                Text("请选择").tag(String?.none)
                ForEach(probe.ids, id: \.self) { Text($0).tag(Optional($0)) }
            }
            HStack {
                Button("定位原通知 / 查看动作") { probe.locate() }
                Button("原通知 AXPress") { probe.perform(kAXPressAction) }
                Button("原通知 AXCancel") { probe.perform(kAXCancelAction) }
            }
            Text("只操作 UUID 或完整测试内容精确匹配的唯一对象；不记录其他通知。退出清除测试通知。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(probe.events.joined(separator: "\n")).font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }.padding(20).frame(width: 760, height: 450)
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let probe = Probe()
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = probe
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 490),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Notification Action PoC"
        window.contentView = NSHostingView(rootView: ProbeView(probe: probe))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: probe.ids)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
