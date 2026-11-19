import SwiftUI
import AudioToolbox

/// 消息列表页：顶部固定翻译助手（置顶、不能删、永远在线，头像用 App logo），
/// 下面是好友列表。点开进聊天页。
/// 好友和消息走服务器（第 8 步）：好友列表以服务器为准；
/// 对方发来的消息轮询拉取（MessageSyncService，聊天页 3 秒、列表页 5 秒），按好友号分到对应会话。
struct MessagesView: View {
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var auth: AuthViewModel
    @ObservedObject private var sync = MessageSyncService.shared
    @State private var path: [MessagesDestination] = []
    @State private var showQuickTranslate = false
    /// 横幅点进来要打开的聊天（MainTabView 填；打开后清掉）。
    @Binding var openChatId: String?

    init(openChatId: Binding<String?> = .constant(nil)) {
        _openChatId = openChatId
    }

    /// 好友行（服务器同步来的好友）+ 非好友会话行（有聊天记录、但还不在好友列表里的人——
    /// 比如对方刚接受请求、本机还没同步，或者对方还没成好友就发了消息；云函数发消息
    /// 不验好友关系，这种消息照样进收件箱，列表页不能没有这一行）。
    private var conversationRows: [(id: String, displayName: String, isFriend: Bool)] {
        var rows: [(id: String, displayName: String, isFriend: Bool)] = friendStore.friends.map {
            (id: $0.id, displayName: friendStore.displayName(for: $0), isFriend: true)
        }
        let friendIds = Set(friendStore.friends.map { $0.id })
        let otherIds = ChatStore.storedConversationIds()
            .filter { $0 != BotAssistant.id && !friendIds.contains($0) }
            .sorted {
                (ChatStore.lastMessageDate(for: $0) ?? .distantPast) >
                (ChatStore.lastMessageDate(for: $1) ?? .distantPast)
            }
        rows += otherIds.map { (id: $0, displayName: "好友 \($0)", isFriend: false) }
        return rows
    }

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
                    // 第 11 步：每行加未读角标（以前没有）；有聊天记录的非好友也显示一行，
                    // 不然对方发了消息、声音也响了，列表上却连行都没有。
                    VStack(spacing: 0) {
                        let rows = conversationRows
                        if rows.isEmpty {
                            Text("还没有好友，去“好友”页输入对方 6 位好友号添加。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 {
                                    Divider().padding(.leading, 76)
                                }
                                Button(action: { path.append(.friend(NativeFriend(id: row.id, nickname: row.displayName))) }) {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(Color(.systemGray5))
                                            Text(String(row.displayName.prefix(1)))
                                                .font(.headline)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 48, height: 48)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(row.displayName)
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            Text(lastPreview(for: row.id) ?? "好友号 \(row.id)")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        // 未读角标：有未读就显示红底数字（99+ 封顶）。
                                        let unread = sync.unreadCount(for: row.id)
                                        if unread > 0 {
                                            Text(unread > 99 ? "99+" : "\(unread)")
                                                .font(.footnote)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2)
                                                .background(Color.red)
                                                .clipShape(Capsule())
                                        }
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
                // 进消息页就拉一次收件箱（lastPollAt 变了会刷新列表预览）；列表页轮询 5 秒。
                // 第 11 步：进页也同步一次好友——对方刚接受请求时，本机好友列表可能还没同步，
                // 不然消息列表里连那一行都没有，消息到了也看不见。
                MessageSyncService.shared.setPollInterval(5)
                Task {
                    await MessageSyncService.shared.pollNow()
                    await friendStore.sync(token: auth.session?.accessToken)
                }
                openPendingChat()
            }
            .onChange(of: openChatId) { _, _ in openPendingChat() }
            .onReceive(NotificationCenter.default.publisher(for: .zyInboxUpdated)) { _ in
                // 收到新消息：如果发消息的人还不在好友列表里，同步一次好友
                // （对方刚接受请求、本机还没同步时，列表上没有那一行）。
                let known = Set(friendStore.friends.map { $0.id })
                if ChatStore.storedConversationIds().contains(where: { $0 != BotAssistant.id && !known.contains($0) }) {
                    Task { await friendStore.sync(token: auth.session?.accessToken) }
                }
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

    /// 横幅点进来要打开的聊天：进消息页（或 openChatId 变化时）打开，打开后清掉。
    private func openPendingChat() {
        guard let id = openChatId, id.count == 6, id.allSatisfy({ $0.isNumber }) else { return }
        openChatId = nil
        let friend = friendStore.friends.first(where: { $0.id == id })
            ?? NativeFriend(id: id, nickname: "好友 \(id)")
        path.append(.friend(friend))
    }
}

/// 消息列表的导航目标（编程式导航用，和“我的”页同款做法）。
enum MessagesDestination: Hashable {
    case bot
    case friend(NativeFriend)
}

// MARK: - 收消息轮询（第 8 步：好友连接；第 9 步：延迟修）
//
// App 在前台时轮询调 GET /inbox 拉新消息，按 from_num 分到对应会话，
// 收到后调 POST /ack 确认。收到新消息响一下系统提示音（App 打开时就行；
// 锁屏推送要 APNs，以后再说，不做假的）。
// 轮询间隔：聊天页 3 秒、消息列表页 5 秒（以前固定 10 秒，消息最晚 10 秒才出现）。
// 轮询由 MainTabView 在前台时启动、切后台时停止；进消息页和聊天页时也会立刻拉一次。

@MainActor
final class MessageSyncService: ObservableObject {
    static let shared = MessageSyncService()

    /// 上次拉取时间（消息列表靠它刷新最后一条预览）。
    @Published private(set) var lastPollAt = Date()
    /// 上次拉取新收到的消息条数。
    @Published private(set) var lastNewCount = 0
    /// 每个会话的未读数（本机存 zy-unread-<会话号>；打开聊天页就清零）。
    /// 第 11 步之前根本没有未读机制：收到消息只有声音，列表行上没有任何标记。
    @Published private(set) var unreadCounts: [String: Int] = [:]
    /// 新消息横幅（不在那个聊天页时才弹；点一下进聊天页，4 秒自己消失）。
    @Published private(set) var newMessageBanner: NewMessageBanner?
    /// 当前打开着的聊天页会话号（ChatView 进页填、离页清；打开着的会话不记未读、不弹横幅）。
    var currentOpenConversationId: String?

    /// 未读总数（消息标签上的角标用）。
    var unreadTotal: Int { unreadCounts.values.reduce(0, +) }

    private let unreadKeyPrefix = "zy-unread-"
    private var bannerClearTask: Task<Void, Never>?

    private var pollTask: Task<Void, Never>?
    private var isPollingNow = false
    /// 轮询间隔（秒）：聊天页 3 秒、列表页 5 秒；循环每次按当前值睡，改了立刻生效。
    private var pollInterval: TimeInterval = 5
    /// 401（登录过期）后暂停轮询 30 秒再试（以前是无限暂停：令牌后来刷新了，
    /// App 不切后台轮询就再也不跑了，消息一直收不到）。
    private var authPausedUntil: Date?
    private var tokenProvider: (() -> String?)?
    private let translator = TranslationService.shared

    private init() { loadUnreadCounts() }

    private func loadUnreadCounts() {
        var counts: [String: Int] = [:]
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(unreadKeyPrefix) {
            let id = String(key.dropFirst(unreadKeyPrefix.count))
            let n = UserDefaults.standard.integer(forKey: key)
            if n > 0 { counts[id] = n }
        }
        unreadCounts = counts
    }

    /// 某会话未读数。
    func unreadCount(for conversationId: String) -> Int {
        unreadCounts[conversationId] ?? 0
    }

    /// 新消息到了、且用户没打开那个聊天页：未读 +1（存本机）。
    func addUnread(for conversationId: String) {
        let n = (unreadCounts[conversationId] ?? 0) + 1
        unreadCounts[conversationId] = n
        UserDefaults.standard.set(n, forKey: unreadKeyPrefix + conversationId)
    }

    /// 打开聊天页就清零该会话未读。
    func clearUnread(for conversationId: String) {
        unreadCounts.removeValue(forKey: conversationId)
        UserDefaults.standard.removeObject(forKey: unreadKeyPrefix + conversationId)
    }

    /// 弹新消息横幅（4 秒后自己消失；新横幅来了旧的直接换掉）。
    func showBanner(conversationId: String, preview: String) {
        bannerClearTask?.cancel()
        newMessageBanner = NewMessageBanner(conversationId: conversationId, preview: preview)
        bannerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.newMessageBanner = nil
        }
    }

    func dismissBanner() {
        bannerClearTask?.cancel()
        bannerClearTask = nil
        newMessageBanner = nil
    }

    /// 换轮询间隔（聊天页进 3 秒、出 5 秒；消息列表页 5 秒）。
    func setPollInterval(_ interval: TimeInterval) {
        pollInterval = interval
    }

    /// 开始轮询（只在 App 在前台时调用；切后台就 stop）。
    /// tokenProvider 每次现取现用（令牌过期时 supabase-swift 会自动刷新）。
    func start(tokenProvider: @escaping () -> String?) {
        self.tokenProvider = tokenProvider
        authPausedUntil = nil
        stop()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollNow()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 回到前台时清掉 401 暂停标记，下次轮询再试。
    func clearAuthPause() {
        authPausedUntil = nil
    }

    /// 拉一次收件箱（GET /inbox）：按 from_num 分到对应会话，收到后调 POST /ack。
    /// 没登录、没网、401 都静默失败，不崩。
    func pollNow() async {
        guard !isPollingNow else { return }
        if let until = authPausedUntil {
            // 401 暂停期过了就自动恢复，不用等切后台。
            if Date() < until { return }
            authPausedUntil = nil
        }
        guard let token = tokenProvider?(), !token.isEmpty else { return }
        isPollingNow = true
        defer { isPollingNow = false }
        guard let result = await WorkerAPI.request(path: "inbox", method: "GET", token: token, as: InboxResponse.self) else { return }
        if result.status == 401 {
            authPausedUntil = Date().addingTimeInterval(30)
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
                // 没打开那个聊天页：未读 +1、弹横幅（打开着的会话不用，聊天页自己会刷新）。
                if incoming.fromNum != currentOpenConversationId {
                    addUnread(for: incoming.fromNum)
                    showBanner(conversationId: incoming.fromNum, preview: incoming.orig)
                }
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

/// 新消息横幅（点一下进那个聊天页）。
struct NewMessageBanner: Identifiable, Equatable {
    var id: String { conversationId + "-" + preview }
    let conversationId: String
    let preview: String
}
