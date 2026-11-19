import SwiftUI
import AudioToolbox

/// 消息列表页：顶部固定翻译助手（置顶、不能删、永远在线，头像用 App logo），
/// 下面是好友列表。点开进聊天页。
/// 好友和消息走服务器（第 8 步）：好友列表以服务器为准；
/// 对方发来的消息每 10 秒拉一次（MessageSyncService），按好友号分到对应会话。
struct MessagesView: View {
    @EnvironmentObject var friendStore: FriendStore
    @ObservedObject private var sync = MessageSyncService.shared
    @State private var path: [MessagesDestination] = []
    @State private var showQuickTranslate = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    // 翻译助手：永远置顶。
                    VStack(spacing: 0) {
                        Button(action: { path.append(.bot) }) {
                            HStack(spacing: 12) {
                                Image("AppLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(BotAssistant.nameZh)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text("Trợ lý dịch")
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                    }
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 8, height: 8)
                                        Text(lastPreview(for: BotAssistant.id) ?? "永远在线，随时可以聊天")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color(.tertiaryLabel))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)

                    // 好友聊天：点按修（第 7 步）——原来是 List + Section 里的 Button，
                    // 好友行点按没反应（只有翻译助手那行能进）。改成和“我的”页、
                    // 个人资料页同款做法：普通 Button + 编程式导航 + 整行宽 + contentShape，
                    // 点行上任何位置都能进聊天页。
                    VStack(spacing: 0) {
                        if friendStore.friends.isEmpty {
                            Text("还没有好友，去“好友”页输入对方 6 位好友号添加。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        } else {
                            ForEach(Array(friendStore.friends.enumerated()), id: \.element.id) { index, friend in
                                if index > 0 {
                                    Divider().padding(.leading, 76)
                                }
                                Button(action: { path.append(.friend(friend)) }) {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(Color(.systemGray5))
                                            Text(String(friendStore.displayName(for: friend).prefix(1)))
                                                .font(.headline)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 48, height: 48)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(friendStore.displayName(for: friend))
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            Text(lastPreview(for: friend.id) ?? "好友号 \(friend.id)")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(Color(.tertiaryLabel))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)

                    Text("好友和消息走服务器，原生两台手机之间互通；和网页版不互通。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("消息")
            .onAppear {
                // 进消息页就拉一次收件箱（lastPollAt 变了会刷新列表预览）。
                Task { await MessageSyncService.shared.pollNow() }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("翻译") { showQuickTranslate = true }
                }
            }
            .navigationDestination(for: MessagesDestination.self) { destination in
                switch destination {
                case .bot:
                    ChatView(conversationId: BotAssistant.id, isBot: true, title: BotAssistant.nameZh)
                case .friend(let friend):
                    ChatView(conversationId: friend.id, isBot: false, title: friendStore.displayName(for: friend))
                }
            }
            .sheet(isPresented: $showQuickTranslate) {
                QuickTranslateView()
            }
        }
    }

    private func lastPreview(for conversationId: String) -> String? {
        ChatStore.lastMessagePreview(for: conversationId)
    }
}

/// 消息列表的导航目标（编程式导航用，和“我的”页同款做法）。
enum MessagesDestination: Hashable {
    case bot
    case friend(NativeFriend)
}

// MARK: - 收消息轮询（第 8 步：好友连接）
//
// App 在前台时每 10 秒调一次 GET /inbox 拉新消息，按 from_num 分到对应会话，
// 收到后调 POST /ack 确认。收到新消息响一下系统提示音（App 打开时就行；
// 锁屏推送要 APNs，以后再说，不做假的）。
// 轮询由 MainTabView 在前台时启动、切后台时停止；进消息页和聊天页时也会立刻拉一次。

@MainActor
final class MessageSyncService: ObservableObject {
    static let shared = MessageSyncService()

    /// 上次拉取时间（消息列表靠它刷新最后一条预览）。
    @Published private(set) var lastPollAt = Date()
    /// 上次拉取新收到的消息条数。
    @Published private(set) var lastNewCount = 0

    private var pollTask: Task<Void, Never>?
    private var isPollingNow = false
    /// 401（登录过期）后暂停轮询，等下次回到前台再试，不狂刷。
    private var authPaused = false
    private var tokenProvider: (() -> String?)?
    private let translator = TranslationService.shared

    private init() {}

    /// 开始每 10 秒轮询（只在 App 在前台时调用；切后台就 stop）。
    /// tokenProvider 每次现取现用（令牌过期时 supabase-swift 会自动刷新）。
    func start(tokenProvider: @escaping () -> String?) {
        self.tokenProvider = tokenProvider
        authPaused = false
        stop()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollNow()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 回到前台时清掉 401 暂停标记，下次轮询再试。
    func clearAuthPause() {
        authPaused = false
    }

    /// 拉一次收件箱（GET /inbox）：按 from_num 分到对应会话，收到后调 POST /ack。
    /// 没登录、没网、401 都静默失败，不崩。
    func pollNow() async {
        guard !isPollingNow, !authPaused else { return }
        guard let token = tokenProvider?(), !token.isEmpty else { return }
        isPollingNow = true
        defer { isPollingNow = false }
        guard let result = await WorkerAPI.request(path: "inbox", method: "GET", token: token, as: InboxResponse.self) else { return }
        if result.status == 401 {
            authPaused = true
            return
        }
        guard result.status == 200, result.value?.ok == true,
              let list = result.value?.messages else { return }
        var rowIds: [Int] = []
        var newCount = 0
        for item in list {
            guard let rowId = item.id,
                  let fromNum = item.from_num, !fromNum.isEmpty,
                  let orig = item.orig, !orig.isEmpty else { continue }
            rowIds.append(rowId)
            let msgId = Int64(item.msg_id ?? 0)
            let trans = item.trans ?? ""
            let fromLang: ChatLanguage = item.from_lang == "vi" ? .vi : .zh
            let ts = Date(timeIntervalSince1970: TimeInterval(item.ts ?? 0) / 1000)
            let incoming = IncomingMessage(
                rowId: rowId, fromNum: fromNum, orig: orig, trans: trans,
                fromLang: fromLang, ts: ts, name: item.name ?? "",
                sess: item.sess ?? "", msgId: msgId
            )
            if let storedMsgId = ChatStore.appendIncoming(incoming) {
                newCount += 1
                // 对方没给译文（发送方翻译失败时 trans 为空）：本机翻译链补译文。
                if trans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var incomingWithId = incoming
                    incomingWithId.msgId = storedMsgId
                    Task { await self.translateIncoming(incomingWithId) }
                }
            }
        }
        if !rowIds.isEmpty {
            _ = await WorkerAPI.request(path: "ack", method: "POST", token: token, body: WorkerAPI.jsonBody(["ids": rowIds]), as: WorkerOK.self)
        }
        lastNewCount = newCount
        lastPollAt = Date()
        if newCount > 0 {
            // 收到新消息响一下系统提示音（1007 是短信收到音）。
            AudioServicesPlaySystemSound(1007)
            NotificationCenter.default.post(name: .zyInboxUpdated, object: nil)
        }
    }

    /// 收到的消息本机补译文，译完刷新聊天页。
    private func translateIncoming(_ incoming: IncomingMessage) async {
        do {
            let trans = try await translator.translate(text: incoming.orig, from: incoming.fromLang, to: incoming.fromLang.other)
            ChatStore.updateTranslation(for: incoming.fromNum, msgId: incoming.msgId, trans: trans)
            NotificationCenter.default.post(name: .zyInboxUpdated, object: nil)
        } catch {
            // 翻译失败就只显示原文。
        }
    }
}

extension Notification.Name {
    /// 收件箱有新消息（消息列表和聊天页靠它刷新）。
    static let zyInboxUpdated = Notification.Name("zy-inbox-updated")
}
