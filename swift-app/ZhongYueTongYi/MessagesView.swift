import SwiftUI

/// 消息页：第一步只做占位界面，后续步骤接入真实消息、翻译与语音消息。
struct MessagesView: View {
    var body: some View {
        NavigationStack {
            PlaceholderView(
                icon: "message.fill",
                title: "消息功能即将推出",
                subtitle: "后续步骤接入真实消息、翻译与语音消息。"
            )
            .navigationTitle("消息")
        }
    }
}

/// 通用占位页：明确告诉用户这是还没做的功能，不冒充已实现。
struct PlaceholderView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
