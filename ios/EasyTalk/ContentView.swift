import SwiftUI
import UIKit

struct ContentView: View {
    @State private var session = TalkSession()
    @State private var showSettings = false
    @State private var confirmClear = false
    @AppStorage(Prefs.fontSize) private var fontSize: Double = 24
    @AppStorage("zhOnly") private var mineOnly = false
    @AppStorage(Prefs.suggestEnabled) private var suggestOn = true
    @AppStorage(Prefs.autoSpeak) private var autoSpeak = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("模式", selection: $session.mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .disabled(session.running)

                Text("\(session.theirs.title) ⇄ \(session.mine.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)

                transcript

                if session.mode == .chat {
                    if suggestOn { SuggestionPanel(session: session) }
                    PhraseBar(session: session, suggestOn: $suggestOn, autoSpeak: $autoSpeak)
                }
                if session.mode == .lecture { lectureBar }
                controls
            }
            .navigationTitle("EasyTalk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusBadge(text: session.status, running: session.running)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(session.running)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { session.reloadLanguages() }) { SettingsView() }
            .onChange(of: suggestOn) { _, on in
                if !on { session.clearSuggestions() }
            }
            .alert("提示", isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )) {
                Button("好") { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
            .confirmationDialog("清空当前记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { session.clear() }
            }
        }
    }

    // MARK: transcript

    private var visible: [Utterance] {
        session.utterances.filter { !$0.enText.isEmpty || !$0.zhText.isEmpty }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if visible.isEmpty { HintView(mode: session.mode, mine: session.mine, theirs: session.theirs) }
                    ForEach(visible) { u in
                        if session.mode == .lecture {
                            ParagraphView(big: session.text(u, in: session.mine),
                                          small: session.text(u, in: session.theirs),
                                          speaker: session.distinctSpeakers > 1 ? session.speakerName(u.speaker) : nil,
                                          pending: u.hasPending, fontSize: fontSize, mineOnly: mineOnly)
                        } else {
                            bubble(u)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: session.revision) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func bubble(_ u: Utterance) -> some View {
        let isMe = session.isMine(u)
        let inTheirs = session.text(u, in: session.theirs)
        let inMine = session.text(u, in: session.mine)
        let theirs = session.theirs
        let speak: (() -> Void)? = (isMe && !inTheirs.isEmpty)
            ? { Speaker.shared.speak(inTheirs, lang: theirs) }
            : nil
        return BubbleView(
            isMe: isMe,
            tag: isMe ? (session.me.contains(u.speaker) ? "我 · 不是我" : "我")
                      : "\(session.speakerName(u.speaker)) · 这是我?",
            // The other person's words: their language small, my language big.
            // My words: my language small, their language big (to show or play to them).
            primary: isMe ? inTheirs : inMine,
            secondary: isMe ? inMine : inTheirs,
            pending: u.hasPending,
            onTag: { session.toggleMe(u.speaker) },
            onSpeak: speak
        )
    }

    // MARK: bars

    private var lectureBar: some View {
        HStack(spacing: 10) {
            Toggle("仅看\(session.mine.title)", isOn: $mineOnly)
                .toggleStyle(.button)
            Button("A−") { fontSize = max(18, fontSize - 2) }
            Button("A+") { fontSize = min(40, fontSize + 2) }
            Spacer()
            ShareLink(item: exportText) { Label("导出", systemImage: "square.and.arrow.up") }
                .disabled(visible.isEmpty)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                Rectangle().fill(.green)
                    .frame(width: g.size.width * CGFloat(min(1, session.level * 1.4)))
            }
            .frame(height: 3)
            HStack(spacing: 12) {
                Button("清空") { confirmClear = true }
                    .disabled(session.running || visible.isEmpty)
                Button {
                    if session.running { session.stop() } else { Task { await session.start() } }
                } label: {
                    Text(session.running ? "停止" : "开始")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(session.running ? Color.red : Color.blue)
            }
            .padding()
        }
        .background(.bar)
    }

    private var exportText: String {
        let multi = session.distinctSpeakers > 1
        var lines = ["EasyTalk \(Date().formatted(date: .abbreviated, time: .shortened))"]
        let topic = UserDefaults.standard.string(forKey: Prefs.topic) ?? ""
        if session.mode == .lecture, !topic.isEmpty { lines.append("主题：\(topic)") }
        lines.append("")
        for u in visible {
            if multi { lines.append("【\(session.speakerName(u.speaker))】") }
            let a = session.text(u, in: session.theirs)
            let b = session.text(u, in: session.mine)
            if !a.isEmpty { lines.append(a) }
            if !b.isEmpty { lines.append(b) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - pieces

struct StatusBadge: View {
    let text: String
    let running: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(running ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 4)
    }
}

struct HintView: View {
    let mode: Mode
    let mine: Lang
    let theirs: Lang
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .chat {
                Text("点下方「开始」，把手机放在你和对方之间。")
                Text("对方说\(theirs.title)：显示原文和**大字\(mine.title)**。")
                Text("你说\(mine.title)：自动翻译成\(theirs.title)并朗读给对方听（🔊 可关）。")
                Text("如果你也说\(theirs.title)，点那条字幕上的标签，把自己标成「我」。")
            } else {
                Text("点下方「开始」，把手机朝向讲话的人。")
                Text("\(mine.title)在上、\(theirs.title)在下；可以在设置里填会议主题，识别专业词会更准。")
            }
            Text("锁屏后会继续收音。不保存录音；清空后记录就没了。")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct BubbleView: View {
    let isMe: Bool
    let tag: String
    let primary: String
    let secondary: String
    let pending: Bool
    let onTag: () -> Void
    let onSpeak: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: onTag) { Text(tag).font(.caption) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Spacer()
                if let onSpeak {
                    Button(action: onSpeak) { Image(systemName: "speaker.wave.2.fill") }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityLabel("朗读")
                }
            }
            if isMe {
                if !primary.isEmpty {
                    Text(primary).font(.system(size: 21, weight: .semibold))
                }
                if !secondary.isEmpty {
                    Text(secondary).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                if !secondary.isEmpty {
                    Text(secondary).font(.subheadline).foregroundStyle(Color.englishText)
                }
                if !primary.isEmpty {
                    Text(primary).font(.system(size: 23, weight: .semibold))
                }
            }
        }
        .opacity(pending ? 0.8 : 1)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isMe ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .padding(.leading, isMe ? 40 : 0)
        .padding(.trailing, isMe ? 0 : 40)
        .textSelection(.enabled)
    }
}

struct ParagraphView: View {
    let big: String
    let small: String
    let speaker: String?
    let pending: Bool
    let fontSize: Double
    let mineOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let speaker {
                Text(speaker).font(.caption).foregroundStyle(.blue)
            }
            if !big.isEmpty {
                Text(big).font(.system(size: fontSize, weight: .semibold))
            }
            if !mineOnly, !small.isEmpty {
                Text(small)
                    .font(.system(size: fontSize * 0.62))
                    .foregroundStyle(Color.englishText)
            }
            Divider().padding(.top, 6)
        }
        .opacity(pending ? 0.8 : 1)
        .textSelection(.enabled)
    }
}

// MARK: - chat helpers

struct SuggestionPanel: View {
    let session: TalkSession
    private var speaker: Speaker { Speaker.shared }

    var body: some View {
        if session.suggestStatus != .idle || !session.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("建议回答").font(.subheadline.bold())
                    Text("点一下朗读").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    statusView
                    Button { session.refreshSuggestions() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(session.suggestStatus == .thinking)
                }
                switch session.suggestStatus {
                case .notConnected:
                    Text("在设置（右上角齿轮）里连接 ChatGPT 后，对方说完会自动给出建议回答。")
                        .font(.footnote).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(.red)
                default:
                    ForEach(session.suggestions) { s in
                        Button { speaker.speak(s.say, lang: session.theirs) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.say).font(.headline).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !s.meaning.isEmpty {
                                    Text(s.meaning).font(.footnote).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(speaker.speakingText == s.say ? Color.blue : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch session.suggestStatus {
        case .thinking:
            ProgressView().controlSize(.small)
        case .done(let seconds):
            Text(String(format: "%.1fs", seconds)).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

struct PhraseBar: View {
    let session: TalkSession
    @Binding var suggestOn: Bool
    @Binding var autoSpeak: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Toggle(isOn: $suggestOn) {
                    Label("建议", systemImage: suggestOn ? "lightbulb.fill" : "lightbulb.slash")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(suggestOn ? Color.orange : Color.gray)
                .accessibilityLabel(suggestOn ? "关闭建议回答" : "开启建议回答")
                Toggle(isOn: $autoSpeak) {
                    Image(systemName: autoSpeak ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(autoSpeak ? Color.green : Color.gray)
                .accessibilityLabel(autoSpeak ? "关闭自动朗读" : "开启自动朗读")
                Divider().frame(height: 24)
                ForEach(Phrase.all) { p in
                    let say = p.say(session.theirs)
                    Button(p.label(session.mine)) { Speaker.shared.speak(say, lang: session.theirs) }
                        .buttonStyle(.bordered)
                        .tint(Speaker.shared.speakingText == say ? Color.blue : Color.gray)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

extension Color {
    /// The other language's captions: a clear sky blue on dark backgrounds, a deep blue on light ones.
    static let englishText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.53, green: 0.80, blue: 1.00, alpha: 1)   // #87CCFF
            : UIColor(red: 0.07, green: 0.33, blue: 0.75, alpha: 1)   // #1254BF
    })
}
