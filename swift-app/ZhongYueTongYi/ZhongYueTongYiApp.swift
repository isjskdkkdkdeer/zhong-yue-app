import SwiftUI

@main
struct ZhongYueTongYiApp: App {
    @StateObject private var auth = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .task {
                    // 监听登录状态变化：登录、退出、Token 刷新都会走到这里。
                    for await (_, session) in SupabaseManager.shared.client.auth.authStateChanges {
                        auth.session = session
                        auth.isLoading = false
                        // 会话恢复/刷新后也要读出本机存的头像和性别。
                        auth.loadLocalProfile()
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        Group {
            if auth.isLoading {
                ProgressView("正在加载…")
            } else if auth.isSignedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
    }
}
