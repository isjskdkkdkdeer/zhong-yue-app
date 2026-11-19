import SwiftUI

/// 消息列表页：顶部固定翻译助手（置顶、不能删、永远在线，头像用 App logo），
/// 下面是本机好友列表。点开进聊天页。
/// 限制：好友列表只存本机，和网页版不互通（网页版好友在浏览器本地存储里）。
struct MessagesView: View {
    @EnvironmentObject var friendStore: FriendStore
    @State private var path: [MessagesDestination] = []
    @State private var showQuickTranslate = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // 翻译助手：永远置顶。
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
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                Section {
                    if friendStore.friends.isEmpty {
                        Text("还没有好友，去“好友”页输入对方 6 位好友号添加。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(friendStore.friends) { friend in
                            Button(action: { path.append(.friend(friend)) }) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(Color(.systemGray5))
                                        Text(String(friend.nickname.prefix(1)))
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(friend.nickname)
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
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("好友列表只存本机，和网页版不互通；好友聊天目前是本机翻译演示，真正的消息收发要等好友连接那一步。")
                }
            }
            .navigationTitle("消息")
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
                    ChatView(conversationId: friend.id, isBot: false, title: friend.nickname)
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
