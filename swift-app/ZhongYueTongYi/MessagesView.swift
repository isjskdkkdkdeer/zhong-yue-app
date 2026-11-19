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

                    Text("好友列表只存本机，和网页版不互通；好友聊天目前是本机翻译演示，真正的消息收发要等好友连接那一步。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
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
