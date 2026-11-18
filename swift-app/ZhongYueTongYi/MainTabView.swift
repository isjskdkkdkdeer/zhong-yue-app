import SwiftUI

/// 主界面：4 个标签，白色栏、图标+文字、当前页 iOS 蓝。
struct MainTabView: View {
    @State private var selectedTab = 0

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
        .tint(Color(red: 0, green: 0.48, blue: 1))
        .toolbarBackground(.white, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
