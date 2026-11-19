import SwiftUI
import AVFoundation

/// 聊天页：气泡里原文 + 翻译上下叠着显示（照网页版样式），带时间；
/// 底部输入框 + 发送；按住麦克风录音（最长 30 秒）发给助手。
struct ChatView: View {
    @EnvironmentObject var auth: AuthViewModel
    @StateObject private var store: ChatStore
    @StateObject private var recorder = VoiceRecorder()

    @State private var inputText = ""
    @State private var isPressingMic = false
    @State private var micHint: String?

    private let isBot: Bool

    init(conversationId: String, isBot: Bool, title: String) {
        self.isBot = isBot
        _store = StateObject(wrappedValue: ChatStore(conversationId: conversationId, isBot: isBot, title: title))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if recorder.isRecording {
                recordingBar
            }
            if let error = store.voiceError {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGroupedBackground))
            }
            if let hint = micHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }
            composer
        }
        .navigationTitle(store.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 好友聊天发消息要带令牌和我的名字；进聊天页就拉一次收件箱。
            store.serverToken = auth.session?.accessToken
            store.myDisplayName = auth.displayName
            Task { await MessageSyncService.shared.pollNow() }
        }
        .onChange(of: auth.session?.accessToken ?? "") { _, newToken in
            store.serverToken = newToken.isEmpty ? nil : newToken
        }
        .onReceive(NotificationCenter.default.publisher(for: .zyInboxUpdated)) { _ in
            // 收件箱拉到新消息：刷新打开着的聊天页。
            store.reload()
        }
        .toolbar {
            if isBot {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.botSpeakEnabled.toggle()
                        if !store.botSpeakEnabled { store.stopSpeaking() }
                    } label: {
                        Image(systemName: store.botSpeakEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                }
            }
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.messages) { message in
                        MessageBubbleView(
                            message: message,
                            isBot: isBot,
                            onRetry: { store.retryTranslation(of: message) },
                            onSpeak: { store.speakMessage(message) },
                            onResend: { store.retrySend(of: message) }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { _, _ in
                if let last = store.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = store.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - 录音条

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
            Text("正在录音 \(recorder.elapsedSeconds) 秒，松开发送")
                .font(.subheadline)
            Spacer()
            Text("最长 30 秒")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - 输入框

    private var composer: some View {
        HStack(spacing: 10) {
            // 麦克风：按住录音，松开发送（照网页版 toggleBotRec 的 30 秒上限）。
            Button(action: {}) {
                Image(systemName: recorder.isRecording ? "mic.fill" : "mic.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(recorder.isRecording ? .red : Color(red: 0, green: 0.48, blue: 1))
            }
            .buttonStyle(.plain)
            .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                isPressingMic = pressing
                recorder.pressActive = pressing
                if pressing {
                    startRecording()
                } else {
                    stopRecordingAndSend()
                }
            }, perform: {})

            TextField("输入消息…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                // 深色模式修（第 7 步）：原来写死白色，深色模式下整个聊天页是黑的，
                // 只有输入框一个大白框。改成 secondarySystemBackground：浅色白底、深色深灰。
                .background(Color(.secondarySystemBackground))
                .cornerRadius(18)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(.systemGray4), lineWidth: 0.5)
                )

            Button(action: sendText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color(.systemGray3)
                        : Color(red: 0, green: 0.48, blue: 1))
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 动作

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        if isBot {
            store.sendBotText(text)
        } else {
            store.sendFriendText(text)
        }
    }

    private func startRecording() {
        guard isBot else {
            micHint = "语音消息先只支持翻译助手，好友语音后续再接"
            return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else {
                    store.voiceError = "用不了麦克风，请检查权限"
                    return
                }
                // 权限弹窗出来时手指可能已经松开：松开了就不再开始录。
                guard recorder.pressActive else { return }
                store.voiceError = nil
                micHint = nil
                recorder.start { url in
                    // 录音结束（松开手指或到 30 秒）：有文件就发给助手识别。
                    if let url {
                        store.sendVoiceFile(url)
                    }
                }
            }
        }
    }

    private func stopRecordingAndSend() {
        guard recorder.isRecording else { return }
        if recorder.elapsedSeconds < 1 {
            // 太短了，按网页版“没听到声音”处理：取消不发。
            recorder.stop(cancelled: true)
            micHint = "录音太短了，再说一遍吧"
        } else {
            recorder.stop()
        }
    }
}

// MARK: - 气泡（原文在上，翻译在下，带时间；失败可点重译）

struct MessageBubbleView: View {
    let message: ChatMessage
    let isBot: Bool
    let onRetry: () -> Void
    let onSpeak: () -> Void
    let onResend: () -> Void

    private var isMe: Bool { message.dir == .me }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe { Spacer(minLength: 48) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    if message.isVoice {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12))
                            .foregroundColor(isMe ? .white.opacity(0.8) : .secondary)
                    }
                    Text(message.orig)
                        .font(.system(size: 16))
                        .foregroundColor(isMe ? .white : .primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                // 深色模式修（第 7 步）：对方气泡原来写死白色，气泡里的字是自适应的 .primary，
                // 深色模式下白字印白气泡看不见。改成 secondarySystemBackground，和输入框同款。
                .background(isMe ? Color(red: 0, green: 0.48, blue: 1) : Color(.secondarySystemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(.systemGray4).opacity(isMe ? 0 : 0.6), lineWidth: 0.5)
                )

                // 翻译：原文下面小一号灰字；翻译中显示“翻译中…”；失败显示重译按钮。
                if message.transFail {
                    Button("点一下重新翻译") { onRetry() }
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                } else if !message.trans.isEmpty {
                    Text(message.trans)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                }

                // 发给对方失败（没网 / 401）：标“未发送”，点一下重发。
                if message.sendFailed && isMe {
                    Button("未发送，点一下重发") { onResend() }
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }

                HStack(spacing: 6) {
                    Text(timeString(message.ts))
                        .font(.system(size: 11))
                        .foregroundColor(Color(.tertiaryLabel))
                    // 助手发的消息可以点小喇叭重听（Google 云端语音）。
                    if !isMe && isBot {
                        Button(action: onSpeak) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(red: 0, green: 0.48, blue: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
            if !isMe { Spacer(minLength: 48) }
        }
    }

    private func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
