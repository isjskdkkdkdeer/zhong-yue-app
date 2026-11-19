import SwiftUI

/// 主界面：4 个标签，白色栏、图标+文字、当前页 iOS 蓝。
/// 好友列表由这里统一持有（FriendStore），消息页和好友页共用。
/// 收消息轮询（第 8 步）也在这里管：进 App 就开始轮询拉收件箱（聊天页 3 秒、列表页 5 秒），
/// 切后台就停，回到前台再开始。
struct MainTabView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @StateObject private var friendStore = FriendStore()
    @ObservedObject private var callManager = CallManager.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            MessagesView()
                .tabItem { Label("消息", systemImage: "message.fill") }
                .tag(0)
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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                MessageSyncService.shared.clearAuthPause()
                startMessagePolling()
                startCallSignaling()
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
    private func startCallSignaling() {
        callManager.configure(myNumber: auth.friendNumber) { number in
            friendStore.friends.contains { $0.id == number }
        }
        callManager.startSignaling()
    }
}
