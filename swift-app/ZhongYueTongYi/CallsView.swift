import SwiftUI

/// 通话页：通话记录（本机存，最多 100 条），点一行可以重拨。
/// 来电只有 App 打开时能收到；App 关着或锁屏接不到来电
/// （锁屏来电要 APNs + CallKit，开发者账号登不进去，卡住了，不做假的）。
struct CallsView: View {
    @ObservedObject private var callManager = CallManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if callManager.callLog.isEmpty {
                    PlaceholderView(
                        icon: "phone.fill",
                        title: "还没有通话记录",
                        subtitle: "在好友聊天页点电话按钮，或在好友行左滑点语音 / 视频，就能打给好友。"
                    )
                } else {
                    List {
                        ForEach(callManager.callLog) { entry in
                            Button {
                                Task {
                                    await callManager.startCall(
                                        to: entry.peerNumber,
                                        displayName: entry.peerName,
                                        isVideo: entry.isVideo
                                    )
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(Color(.systemGray5))
                                        Text(String(entry.peerName.prefix(1)))
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.peerName)
                                            .foregroundColor(.primary)
                                        Text(callDetail(entry))
                                            .font(.footnote)
                                            .foregroundColor(entry.missed ? .red : .secondary)
                                    }
                                    Spacer()
                                    Image(systemName: entry.isVideo ? "video.fill" : "phone.fill")
                                        .foregroundColor(Color(red: 0, green: 0.48, blue: 1))
                                }
                            }
                        }
                        Section {
                            Text("来电只有 App 打开时能收到；App 关着或锁屏接不到来电（以后接推送再支持）。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("通话")
        }
    }

    private func callDetail(_ entry: CallLogEntry) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        let time = fmt.string(from: entry.startedAt)
        let dir = entry.direction == "in" ? "打来" : "打出"
        if entry.missed { return "未接来电 · \(time)" }
        if entry.duration > 0 {
            return "\(dir) · \(formatDuration(entry.duration)) · \(time)"
        }
        return "\(dir) · \(time)"
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        return String(format: "%d 分 %02d 秒", seconds / 60, seconds % 60)
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
