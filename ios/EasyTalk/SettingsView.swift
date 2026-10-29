import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sonioxKey = Keychain.get(Keychain.sonioxAccount) ?? ""
    @AppStorage(Prefs.scene) private var scene = TalkScene.work.rawValue
    @AppStorage(Prefs.topic) private var topic = ""
    @AppStorage(Prefs.terms) private var terms = ""
    @AppStorage(Prefs.chatgptModel) private var chatgptModel = ""
    @AppStorage(Prefs.chatgptModels) private var modelsCSV = ""
    @State private var chatgpt = ChatGPTStore.load()
    @State private var connecting = false
    @State private var chatgptMessage: String?
    @State private var auth = ChatGPTAuth()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("粘贴 Soniox API Key", text: $sonioxKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Soniox")
                } footer: {
                    Text(sonioxKey.isEmpty ? "还没有填写。" : "已填写（\(sonioxKey.count) 个字符）。只保存在这台 iPhone 的钥匙串里。")
                }

                Section {
                    if let rec = chatgpt, rec.hasTokens, rec.planGranted {
                        LabeledContent("已连接", value: rec.email ?? "ChatGPT")
                        Picker("模型", selection: $chatgptModel) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        Button("断开连接", role: .destructive) {
                            ChatGPTStore.signOut()
                            chatgpt = ChatGPTStore.load()
                            chatgptMessage = nil
                        }
                    } else {
                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                Text("连接 ChatGPT")
                                if connecting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(connecting)
                    }
                } header: {
                    Text("ChatGPT（建议回答）")
                } footer: {
                    Text(chatgptMessage ?? "用你自己的 ChatGPT Plus 套餐生成建议回答。登录时请允许「Use your ChatGPT plan」。登录凭据只保存在这台 iPhone。")
                }

                Section("对话场景") {
                    Picker("场景", selection: $scene) {
                        ForEach(TalkScene.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }

                Section("会议演讲主题（可选）") {
                    TextField("例如：Q3 sales review、糖尿病讲座", text: $topic)
                }

                Section {
                    TextEditor(text: $terms)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("词表（\(parseTerms(terms).terms.count) 个）")
                } footer: {
                    Text("每行一个常用词或易错说法，例如 due on Monday；写成「OHIP = 安省医保」还能指定翻译。下次点「开始」时生效。")
                }
            }
            .navigationTitle("设置")
            .onAppear(perform: ensureModel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Keychain.set(Keychain.sonioxAccount,
                                     sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }

    private var models: [String] {
        let list = modelsCSV.split(separator: ",").map(String.init)
        if chatgptModel.isEmpty || list.contains(chatgptModel) { return list }
        return [chatgptModel] + list
    }

    private func ensureModel() {
        if chatgptModel.isEmpty, let first = models.first { chatgptModel = first }
    }

    private func connect() async {
        connecting = true
        chatgptMessage = nil
        defer { connecting = false }
        do {
            _ = try await auth.signIn()
            chatgpt = ChatGPTStore.load()
            let list = (try? await ChatGPTClient.listModels()) ?? []
            if !list.isEmpty { modelsCSV = list.joined(separator: ",") }
            if chatgptModel.isEmpty || !list.contains(chatgptModel) {
                chatgptModel = list.first(where: { $0 == "gpt-6-luna" })
                    ?? list.first(where: { $0.contains("luna") }) ?? list.first ?? "gpt-6-luna"
            }
            chatgptMessage = "已连接 ChatGPT。对方说完一轮后，会自动给出建议回答。"
        } catch {
            chatgpt = ChatGPTStore.load()
            chatgptMessage = "连接失败：\(error.localizedDescription)"
        }
    }
}
