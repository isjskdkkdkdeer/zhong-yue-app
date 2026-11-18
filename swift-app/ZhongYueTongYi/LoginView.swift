import SwiftUI

/// 登录页：邮箱 + 密码，Supabase Auth（沿用现有账号体系）。
struct LoginView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var showRegisterNote = false

    private var canLogin: Bool {
        !email.isEmpty && !password.isEmpty && !isBusy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 60)

                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))

                VStack(spacing: 6) {
                    Text("中越通译")
                        .font(.system(size: 28, weight: .bold))
                    Text("中越翻译，让对话自然发生")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 12) {
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)

                if let error = auth.authError {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal, 24)
                }

                Button(action: login) {
                    if isBusy {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("登录")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color(red: 0, green: 0.48, blue: 1))
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal, 24)
                .disabled(!canLogin)
                .opacity(canLogin ? 1 : 0.5)

                Button("没有账号？去注册") {
                    showRegisterNote = true
                }
                .font(.footnote)
                .alert("注册", isPresented: $showRegisterNote) {
                    Button("知道了", role: .cancel) { }
                } message: {
                    Text("注册功能即将推出，请先在网页版注册账号。")
                }

                Spacer()
            }
        }
    }

    private func login() {
        isBusy = true
        Task {
            await auth.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            isBusy = false
        }
    }
}
