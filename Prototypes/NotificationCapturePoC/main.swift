import AppKit
import ApplicationServices
import SwiftUI

private struct Capture: Identifiable {
    let id = UUID()
    let date = Date()
    let process: String
    let text: String
}

private struct ScanResult: Sendable {
    var snapshots: [(process: String, text: String)] = []
    var diagnostics: [String] = []
}

// Read-only: no AX actions, notification dismissal, database access, or network access.
private func scanNotifications() -> ScanResult {
    var result = ScanResult()
    for bundleID in ["com.apple.UserNotificationCenter", "com.apple.notificationcenterui"] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            result.diagnostics.append("\(bundleID): 未运行")
            continue
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var rawWindows: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &rawWindows)
        guard error == .success, let windows = rawWindows as? [AXUIElement] else {
            result.diagnostics.append("\(bundleID): AXWindows 错误 \(error.rawValue)")
            continue
        }
        var nodeCount = 0
        var errorCount = 0
        var truncated = false
        let deadline = Date().addingTimeInterval(2)
        var seen: Set<AXUIElement> = []

        func walk(_ element: AXUIElement, depth: Int, lines: inout [String]) {
            guard depth <= 18, nodeCount < 800, Date() < deadline else {
                truncated = true
                return
            }
            guard seen.insert(element).inserted else { return }
            nodeCount += 1
            var fields: [String] = []
            for attribute in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                if status == .success, let text = value as? String, !text.isEmpty {
                    fields.append("\(attribute)=\(text)")
                } else if status != .success && status != .attributeUnsupported && status != .noValue {
                    errorCount += 1
                }
            }
            if !fields.isEmpty {
                lines.append(String(repeating: "  ", count: depth) + fields.joined(separator: " | "))
            }
            var children: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            if status == .success, let elements = children as? [AXUIElement] {
                for child in elements {
                    guard Date() < deadline, nodeCount < 800 else {
                        truncated = true
                        break
                    }
                    walk(child, depth: depth + 1, lines: &lines)
                }
            } else if status != .success && status != .attributeUnsupported && status != .noValue {
                errorCount += 1
            }
        }

        for window in windows {
            var lines: [String] = []
            walk(window, depth: 0, lines: &lines)
            if !lines.isEmpty {
                result.snapshots.append((bundleID, lines.joined(separator: "\n")))
            }
        }
        result.diagnostics.append("\(bundleID): \(windows.count) 窗口 / \(nodeCount) 节点 / \(errorCount) 读取错误\(truncated ? " / 达到扫描上限，内容可能不全" : "")")
    }
    return result
}

@MainActor
private final class CaptureModel: ObservableObject {
    @Published var captures: [Capture] = []
    @Published var status = "尚未启动。授权后点击开始读取；通知内容只显示在此窗口，不写日志或文件。"
    @Published var running = false
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var fingerprints: Set<String> = []
    private var session = UUID()

    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        status = AXIsProcessTrustedWithOptions(options)
            ? "已有辅助功能权限，可以开始读取。"
            : "请在系统设置 → 隐私与安全性 → 辅助功能中允许 Notification Capture PoC，再点击开始读取。"
    }

    func start() {
        guard !running else { return }
        guard AXIsProcessTrusted() else {
            status = "尚无辅助功能权限。请先点击授权按钮并在系统设置中允许此 App。"
            return
        }
        running = true
        session = UUID()
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        running = false
        session = UUID()
        timer?.invalidate()
        timer = nil
        status = "已停止。已捕获的快照继续保留，退出 App 后清空。"
    }

    func clear() {
        captures.removeAll()
        fingerprints.removeAll()
    }

    private func scan() {
        guard running, scanTask == nil else { return }
        guard AXIsProcessTrusted() else {
            stop()
            status = "辅助功能权限已失效，读取已停止。"
            return
        }
        let currentSession = session
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { scanNotifications() }.value
            guard let self else { return }
            self.scanTask = nil
            guard self.running, self.session == currentSession else { return }
            for snapshot in result.snapshots {
                let fingerprint = snapshot.process + "\n" + snapshot.text
                if self.fingerprints.insert(fingerprint).inserted {
                    self.captures.insert(Capture(process: snapshot.process, text: snapshot.text), at: 0)
                }
            }
            self.status = "最近扫描 \(Date().formatted(date: .omitted, time: .standard))\n" + result.diagnostics.joined(separator: "\n")
        }
    }
}

private struct CaptureView: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("系统通知内容读取 PoC").font(.title.bold())
            Text("验证真实通知的标题和正文是否出现在辅助功能树中。快照不会自动消失；它不是逐条消息解析器。")
                .foregroundStyle(.secondary)
            HStack {
                Button("1. 授权辅助功能", action: model.requestPermission)
                Button(model.running ? "停止读取" : "2. 开始读取") {
                    if model.running { model.stop() } else { model.start() }
                }
                Spacer()
                Text("\(model.captures.count) 个不同快照")
                Button("清空快照", action: model.clear)
            }
            Text(model.status).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(Color.secondary.opacity(0.1)).cornerRadius(8)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.captures.isEmpty {
                        Text("等待快照。开始后让任意应用产生一条普通通知；横幅消失后，检查这里是否仍保留实际标题和正文。")
                            .font(.system(size: 20)).frame(width: 720, alignment: .leading).padding()
                    }
                    ForEach(model.captures) { capture in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(capture.date.formatted(date: .omitted, time: .standard)) · \(capture.process)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(capture.text).font(.system(size: 20, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        }
                        .padding(16).frame(minWidth: 720, alignment: .leading)
                        .background(Color.secondary.opacity(0.08)).cornerRadius(10)
                    }
                }.padding(4)
            }
        }.padding(20).frame(minWidth: 820, minHeight: 560)
    }
}

@main
private struct NotificationCapturePoC: App {
    @StateObject private var model = CaptureModel()

    var body: some Scene {
        WindowGroup("Notification Capture PoC") {
            CaptureView(model: model)
        }.defaultSize(width: 1000, height: 740)
    }
}
