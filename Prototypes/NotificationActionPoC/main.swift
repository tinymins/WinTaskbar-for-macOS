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
    private var productionTargets: [String: NotificationOriginalAction] = [:]
    private var summaries: [String: String] = [:]
    private var windows: [String: AXUIElement] = [:]
    let bannerVisibility = NotificationBannerVisibility()

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
        windows[id] = match.1
        for (label, element) in [("测试卡片", match.0), ("所属窗口", match.1)] {
            var fields: [String] = []
            for key in [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, "AXHidden"] {
                var writable: DarwinBoolean = false
                let check = AXUIElementIsAttributeSettable(element, key as CFString, &writable)
                var raw: CFTypeRef?
                let read = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
                var geometry = ""
                if let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
                    let ax = raw as! AXValue
                    if AXValueGetType(ax) == .cgPoint {
                        var point = CGPoint.zero
                        AXValueGetValue(ax, .cgPoint, &point)
                        geometry = "\(point)"
                    } else if AXValueGetType(ax) == .cgSize {
                        var size = CGSize.zero
                        AXValueGetValue(ax, .cgSize, &size)
                        geometry = "\(size)"
                    }
                }
                fields.append("\(key): read=\(read.rawValue) settable=\(check.rawValue)/\(writable.boolValue) \(geometry)")
            }
            note("\(label)隐藏能力：\(fields.joined(separator: "; "))")
        }
        // The scope check above authorizes reading only this synthetic notification subtree.
        var processID: pid_t = 0
        AXUIElementGetPid(match.0, &processID)
        let application = AXUIElementCreateApplication(processID)
        var focused: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
        note("系统窗口焦点：active=\(NSRunningApplication(processIdentifier: processID)?.isActive == true) status=\(focusStatus.rawValue) hasFocus=\(focused != nil)")
        let snapshot = NotificationAXSnapshot.read(match.0, deadline: ProcessInfo.processInfo.systemUptime + 0.5)
        let contents = snapshot.tree?.notifications(processID: processID) ?? []
        if contents.count == 1, let content = contents.first {
            productionTargets[id] = NotificationOriginalAction.find(in: snapshot, content: content, processID: processID)
        }
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

    func performProductionAction() {
        guard let id = selectedID, let target = productionTargets[id] else { note("尚未捕获正式实现的目标。"); return }
        guard isOwnTarget(target.element, id: id) else {
            // The production action must independently reject the expired reference as well.
            let result = target.press()
            note("正式实现：\(String(describing: result))；原测试对象已失效。")
            return
        }
        note("正式实现：\(String(describing: target.press()))；等待系统消息回调确认。")
    }

    func hideSyntheticBanner() {
        guard let id = selectedID, let target = targets[id], let window = windows[id],
              isOwnTarget(target, id: id) else { note("测试横幅已失效。"); return }
        var visited = Set<AXUIElement>()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        func exclusivelyOwn(_ node: AXUIElement) -> Bool {
            if CFEqual(node, target) { return true }
            guard visited.count < 100, visited.insert(node).inserted,
                  ProcessInfo.processInfo.systemUptime < deadline else { return false }
            var role: CFTypeRef?
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success,
                  ["AXWindow", "AXGroup", "AXScrollArea", "AXLayoutArea"].contains(role as? String ?? ""),
                  AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                  let children = children as? [AXUIElement] else { return false }
            return children.allSatisfy(exclusivelyOwn)
        }
        guard exclusivelyOwn(window) else { note("窗口并非仅含本条测试通知，拒绝移动。"); return }
        note("正式隐藏实现：\(bannerVisibility.hide(window))；8 秒后自动恢复窗口位置。")
        inventory()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.bannerVisibility.restoreAll()
            self?.note("已执行窗口位置恢复。")
        }
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
                Button("正式实现点击") { probe.performProductionAction() }
            }
            Button("只隐藏测试横幅（不关闭）") { probe.hideSyntheticBanner() }
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
        probe.bannerVisibility.setEnabled(false)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: probe.ids)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
