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
