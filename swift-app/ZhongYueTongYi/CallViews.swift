import SwiftUI
import WebRTC

// MARK: - 通话界面（第 10 步：原生语音视频通话）
//
// 来电界面和通话中界面都由 MainTabView 用 fullScreenCover 弹出来，
// 不管当时在哪个标签页，来电都能盖在最上面。
// 来电只有 App 打开时能收到（锁屏来电要 APNs + CallKit，开发者账号登不进去，
// 卡住了，不做假的；通话页底下也写了这句）。

/// RTC 视频画面：UIViewRepresentable 包装 RTCMTLVideoView，
/// 轨道换了就把旧的渲染器拆下来、挂新的。
struct RTCVideoView: UIViewRepresentable {
    var track: RTCVideoTrack?

    final class Coordinator {
        var track: RTCVideoTrack?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            if let old = context.coordinator.track { old.remove(uiView) }
            if let track = track { track.add(uiView) }
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        if let track = coordinator.track { track.remove(uiView) }
        coordinator.track = nil
    }
}

/// 来电界面：全屏黑底，头像 + 名字 + 语音/视频来电，接听（绿）/ 挂断（红）。
/// 响的是用户在“我的”页选的来电铃声。
struct IncomingCallView: View {
    @ObservedObject var manager = CallManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 90)
                ZStack {
                    Circle().fill(Color(.systemGray5))
                    Text(String(manager.peerDisplayName.prefix(1)))
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 96, height: 96)
                .padding(.bottom, 16)
                Text(manager.peerDisplayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Text(manager.isVideoCall ? "视频通话来电" : "语音通话来电")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.top, 6)
                Text("好友号 \(manager.peerNumber)")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 4)
                Spacer()
                HStack(spacing: 64) {
                    // 拒接。
                    Button {
                        manager.declineIncoming()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .frame(width: 72, height: 72)
                                .background(Color.red)
                                .clipShape(Circle())
                            Text("挂断")
                                .font(.subheadline)
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    // 接听。
                    Button {
                        Task { await manager.acceptIncoming() }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: manager.isVideoCall ? "video.fill" : "phone.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .frame(width: 72, height: 72)
                                .background(Color.green)
                                .clipShape(Circle())
                            Text("接听")
                                .font(.subheadline)
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 64)
            }
        }
    }
}

/// 通话中界面：视频是对方画面全屏 + 自己小窗；语音是头像 + 名字 + 时长。
/// 下面一排：静音、免提、（视频才有）开关视频、切换摄像头、挂断。
struct ActiveCallView: View {
    @ObservedObject var manager = CallManager.shared

    var body: some View {
        ZStack {
            if manager.isVideoCall {
                // 对方画面全屏（还没来就黑底等着）。
                ZStack {
                    Color.black.ignoresSafeArea()
                    RTCVideoView(track: manager.remoteVideoTrack)
                        .ignoresSafeArea()
                }
                // 自己小窗：右下角。
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        RTCVideoView(track: manager.localVideoTrack)
                            .frame(width: 108, height: 144)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                            )
                            .padding(.trailing, 16)
                            .padding(.bottom, 150)
                    }
                }
            } else {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 12) {
                    Spacer().frame(height: 110)
                    ZStack {
                        Circle().fill(Color(.systemGray5))
                        Text(String(manager.peerDisplayName.prefix(1)))
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 96, height: 96)
                    Text(manager.peerDisplayName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(callStatusLine)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            // 顶部：名字 + 状态 + 时长（视频模式下白字）。
            VStack(spacing: 4) {
                Text(manager.peerDisplayName)
                    .font(.headline)
                    .foregroundColor(manager.isVideoCall ? .white : .primary)
                Text(callStatusLine)
                    .font(.subheadline)
                    .foregroundColor(manager.isVideoCall ? .white.opacity(0.8) : .secondary)
                Spacer()
            }
            .padding(.top, 56)

            // 底部按钮。
            VStack(spacing: 20) {
                Spacer()
                HStack(spacing: 28) {
                    callButton(
                        icon: manager.isMuted ? "mic.slash.fill" : "mic.fill",
                        label: "静音",
                        isOn: manager.isMuted,
                        action: { manager.toggleMute() }
                    )
                    callButton(
                        icon: "speaker.wave.2.fill",
                        label: "免提",
                        isOn: manager.isSpeakerOn,
                        action: { manager.toggleSpeaker() }
                    )
                    if manager.isVideoCall {
                        callButton(
                            icon: manager.isVideoEnabled ? "video.fill" : "video.slash.fill",
                            label: "视频",
                            isOn: manager.isVideoEnabled,
                            action: { manager.toggleVideo() }
                        )
                        callButton(
                            icon: "arrow.triangle.2.circlepath.camera.fill",
                            label: "切换",
                            isOn: false,
                            action: { manager.switchCamera() }
                        )
                    }
                }
                // 挂断。
                Button {
                    manager.hangup()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 48)
            }
        }
    }

    /// 状态行：拨出显示“正在呼叫…”；接通后显示时长。
    private var callStatusLine: String {
        if manager.state == .outgoing { return "正在呼叫…" }
        if manager.callDuration > 0 { return formatDuration(manager.callDuration) }
        return manager.callStatusText.isEmpty ? "正在连接…" : manager.callStatusText
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func callButton(icon: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(isOn ? Color(red: 0, green: 0.48, blue: 1) : Color.white.opacity(0.25))
                    .clipShape(Circle())
                Text(label)
                    .font(.footnote)
                    .foregroundColor(manager.isVideoCall ? .white : .primary)
            }
        }
        .buttonStyle(.plain)
    }
}
