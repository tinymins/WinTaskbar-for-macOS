import AppKit
import SwiftUI

// Windows 11's attribution row and compact text hierarchy, with expansion for long messages.
struct NotificationCardView: View {
    let content: SystemNotificationContent
    let icon: NSImage?
    let width: CGFloat
    let metrics: NotificationCardMetrics
    let expanded: Bool
    let queued: Int
    let toggleExpanded: () -> Void
    let dismiss: () -> Void
    let clearAll: () -> Void
    let hover: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16).accessibilityHidden(true)
                Text(content.appName).font(.system(size: 13)).foregroundStyle(.secondary)
                    .lineLimit(1).help(content.appName)
                Spacer(minLength: 0)
                if queued > 0 {
                    Text("+\(queued)").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help(String(format: NSLocalizedString("%ld more notifications waiting", comment: "Queued notifications"), queued))
                }
                HStack(spacing: 2) {
                    if metrics.canExpand {
                        Button(action: toggleExpanded) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        }
                        .buttonStyle(NotificationControlStyle())
                        .help(LocalizedStringKey(expanded ? "Collapse notification" : "Expand notification"))
                        .accessibilityLabel(Text(LocalizedStringKey(expanded ? "Collapse notification" : "Expand notification")))
                    }
                    Menu {
                        Button("Clear notification cards", action: clearAll)
                        Divider()
                        Button("Open system notification settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Notification options").accessibilityLabel("Notification options")
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(NotificationControlStyle())
                        .help("Dismiss notification").accessibilityLabel("Dismiss notification")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(height: 28)

            Group {
                if expanded {
                    ScrollView {
                        NotificationCardText(content: content, expanded: true)
                            .textSelection(.enabled)
                    }
                } else {
                    NotificationCardText(content: content, expanded: false)
                }
            }
            .frame(height: metrics.textHeight, alignment: .topLeading)
            .clipped()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
        .frame(width: width, height: metrics.height, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            shape.fill(.regularMaterial)
                .overlay(shape.fill(Color(white: colorScheme == .dark ? 0.16 : 0.97).opacity(0.85)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.09 : 0.65), lineWidth: 1)
        }
        .onHover(perform: hover)
    }
}

private struct NotificationCardText: View {
    let content: SystemNotificationContent
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !content.title.isEmpty {
                Text(content.title).font(.system(size: 15, weight: .semibold))
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.body.isEmpty {
                Text(content.body).font(.system(size: 15)).lineSpacing(3)
                    .lineLimit(expanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NotificationCardMetrics {
    let textHeight: CGFloat
    let canExpand: Bool
    var height: CGFloat { textHeight + 72 }

    @MainActor
    static func measure(_ content: SystemNotificationContent, width: CGFloat, maxHeight: CGFloat, expanded: Bool) -> Self {
        func textHeight(expanded: Bool) -> CGFloat {
            let view = NSHostingView(rootView: NotificationCardText(content: content, expanded: expanded)
                .frame(width: width - 40).fixedSize(horizontal: false, vertical: true))
            return ceil(view.fittingSize.height)
        }
        let compact = textHeight(expanded: false)
        let full = textHeight(expanded: true)
        let available = max(0, maxHeight - 72)
        return Self(textHeight: min(expanded ? full : compact, available), canExpand: full > min(compact, available))
    }
}

private struct NotificationControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Control(configuration: configuration)
    }

    private struct Control: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label.frame(width: 28, height: 28)
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle()).onHover { hovered = $0 }
        }
    }
}
