import SwiftUI

/// 通话页：第一步只做占位界面，后续步骤接入 WebRTC 语音视频通话与 CallKit 来电铃声。
struct CallsView: View {
    var body: some View {
        NavigationStack {
            PlaceholderView(
                icon: "phone.fill",
                title: "通话功能即将推出",
                subtitle: "后续步骤接入 WebRTC 语音视频通话与 CallKit 来电铃声。"
            )
            .navigationTitle("通话")
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
