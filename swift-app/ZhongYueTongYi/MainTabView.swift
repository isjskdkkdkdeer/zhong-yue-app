import SwiftUI

/// 主界面：4 个标签，白色栏、图标+文字、当前页 iOS 蓝。
/// 好友列表由这里统一持有（FriendStore），消息页和好友页共用。
/// 收消息轮询（第 8 步）也在这里管：进 App 就开始轮询拉收件箱（聊天页 3 秒、列表页 5 秒），
/// 切后台就停，回到前台再开始。
/// 第 11 步：消息标签上有未读角标；新消息横幅盖在最上面（点一下进聊天页）；
/// 进 App / 回前台同步一次好友（对方刚接受请求时，本机列表不及时同步，
/// 消息列表会没有那一行、来电也会被当成陌生号码悄悄丢掉）。
struct MainTabView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @StateObject private var friendStore = FriendStore()
    @ObservedObject private var callManager = CallManager.shared
    @ObservedObject private var sync = MessageSyncService.shared
    /// 横幅点进来要打开的聊天（传给消息页；打开后清掉）。
    @State private var pendingOpenChatId: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            MessagesView(openChatId: $pendingOpenChatId)
                .tabItem { Label("消息", systemImage: "message.fill") }
                .tag(0)
                .modifier(TabBadgeModifier(count: sync.unreadTotal))
            FriendsView()
                .tabItem { Label("好友", systemImage: "person.2.fill") }
                .tag(1)
            CallsView()
                .tabItem { Label("通话", systemImage: "phone.fill") }
                .tag(2)
            MeView()
                .tabItem { Label("我的", systemImage: "person.fill") }
                .tag(3)
        }
        .environmentObject(friendStore)
        .tint(Color(red: 0, green: 0.48, blue: 1))
        .toolbarBackground(Color(.systemBackground), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            startMessagePolling()
            startCallSignaling()
            Task { await friendStore.sync(token: auth.session?.accessToken) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                MessageSyncService.shared.clearAuthPause()
                startMessagePolling()
                startCallSignaling()
                Task { await friendStore.sync(token: auth.session?.accessToken) }
            } else {
                // 切后台就停轮询和来电信令（只在前台收消息、接来电）。
                MessageSyncService.shared.stop()
                Task { await CallManager.shared.stopSignaling() }
            }
        }
        .onDisappear {
            MessageSyncService.shared.stop()
            Task { await CallManager.shared.stopSignaling() }
        }
        // 新消息横幅：不管在哪个标签页都盖在最上面，点一下进那个聊天页。
        .overlay(alignment: .top) {
            if let banner = sync.newMessageBanner {
                NewMessageBannerView(
                    banner: banner,
                    displayName: friendStore.friends.first(where: { $0.id == banner.conversationId })
                        .map { friendStore.displayName(for: $0) } ?? "好友 \(banner.conversationId)",
                    onTap: {
                        sync.dismissBanner()
                        pendingOpenChatId = banner.conversationId
                        selectedTab = 0
                    },
                    onClose: { sync.dismissBanner() }
                )
                .padding(.top, 8)
                .padding(.horizontal, 12)
            }
        }
        // 来电界面：不管在哪个标签页都盖在最上面。
        .fullScreenCover(item: $callManager.incomingInvitation) { _ in
            IncomingCallView()
        }
        // 拨出 / 通话中界面。
        .fullScreenCover(isPresented: $callManager.showActiveCall) {
            ActiveCallView()
        }
        // 通话弹框（权限没开 / 对方挂断 / 对方正忙等）。
        .alert(item: $callManager.callAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: alert.showSettings
                    ? .default(Text("去设置")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    : .default(Text("知道了")),
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    /// 开始收消息轮询：轮询调 GET /inbox 拉一次（令牌每次现取现用）。
    private func startMessagePolling() {
        MessageSyncService.shared.start(tokenProvider: { auth.session?.accessToken })
    }

    /// 开始来电信令：订阅我的来电频道（第 10 步：Supabase Realtime Broadcast）。
    /// 好友号没设好就订阅不了，别人也打不进来。
    /// 好友校验走服务器兜底（第 11 步）：只看本机列表会误判——对方刚接受请求时，
    /// 本机列表可能还没同步，真好友会被当成陌生号码、来电悄悄丢掉。
    private func startCallSignaling() {
        callManager.configure(myNumber: auth.friendNumber) { number in
            await friendStore.isFriend(number, token: auth.session?.accessToken)
        }
        callManager.startSignaling()
    }
}

/// 消息标签上的未读角标（有未读才显示；0 就不显示）。
struct TabBadgeModifier: ViewModifier {
    let count: Int

    func body(content: Content) -> some View {
        if count > 0 {
            content.badge(count)
        } else {
            content
        }
    }
}

/// 新消息横幅：发消息的人 + 消息预览，点一下进聊天页。
struct NewMessageBannerView: View {
    let banner: NewMessageBanner
    let displayName: String
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(.systemGray5))
                    Text(String(displayName.prefix(1)))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(banner.preview)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}
