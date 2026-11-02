import SwiftUI

enum Palette {
    static let canvas = Color("Canvas")
    static let panel = Color("Panel")
    static let ink = Color("Ink")
    static let secondary = Color("Secondary")
    static let accent = Color("Accent")
    static let line = Color("Line")
}

struct ConversationView: View {
    @Bindable var conversation: Conversation
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 0) {
                VoiceStage(conversation: conversation)
                    .frame(width: 340)
                Rectangle().fill(Palette.line).frame(width: 1)
                ConversationPanel(conversation: conversation)
            }
        }
        .background(Palette.canvas)
        .foregroundStyle(Palette.ink)
        .frame(minWidth: 900, minHeight: 690)
        .task { await conversation.prepare() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await conversation.refreshAvailability() } }
            if scenePhase == .background && [.listening, .requestingMicrophone, .finishing].contains(conversation.phase) {
                conversation.stop()
            }
        }
        .onDisappear { conversation.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 38, height: 38)
                .background(Palette.accent.opacity(0.08), in: .rect(cornerRadius: 12))
            Text("rona").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-1.5)
            Text("VOICE").font(.system(size: 10, weight: .medium)).tracking(2.5)
                .foregroundStyle(Palette.secondary).padding(.leading, 3)
            Spacer()
            Label("On this Mac", systemImage: "lock.shield")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(Palette.panel, in: .capsule)
                .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
                .help("Your conversations are processed on this Mac. No account, server, or saved transcript.")
        }
        .padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 22)
    }
}

private struct VoiceStage: View {
    @Bindable var conversation: Conversation

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 630
        VStack(alignment: .leading, spacing: 0) {
            Text("A MOMENT FOR YOUR MIND")
                .font(.system(size: 9, weight: .semibold)).tracking(2.1)
                .foregroundStyle(Palette.secondary)
                .padding(.top, compact ? 24 : 38)
            Text("Room to\nthink aloud.")
                .font(.system(size: compact ? 34 : 40, weight: .regular, design: .serif))
                .tracking(-1.6).lineSpacing(-1).padding(.top, 15)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Room to think aloud.")
            Text("An open conversation.\nA little more clarity.")
                .font(.system(size: 13)).lineSpacing(5)
                .foregroundStyle(Palette.secondary).padding(.top, 14)

            Spacer(minLength: 8)
            VoiceOrb(active: conversation.phase.isWorking, level: conversation.microphoneLevel)
                .scaleEffect(compact ? 0.82 : 1)
                .frame(height: compact ? 172 : 206).frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            HStack(spacing: 7) {
                Circle().fill(conversation.phase == .listening ? Color.green : Palette.accent.opacity(0.7))
                    .frame(width: 5, height: 5)
                Text(conversation.phase.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conversationStatus")

            Spacer(minLength: 24)
            Button(action: conversation.microphoneTapped) {
                Label(microphoneTitle, systemImage: conversation.phase == .listening ? "arrow.up" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundStyle(.white)
                    .background(Palette.accent, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(!conversation.canListen || conversation.phase == .finishing || conversation.phase == .requestingMicrophone)
            .opacity(conversation.canListen ? 1 : 0.5)
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .accessibilityIdentifier("microphoneButton")
            .help("Start a voice conversation. Pause to send, or tap again. ⌘⇧M")

            HStack {
                if conversation.phase.isWorking || conversation.voiceConversation {
                    Button("End conversation", systemImage: "stop.fill", action: conversation.stop)
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
                        .accessibilityIdentifier("stopButton")
                } else {
                    Text("Speak freely. Pause to send.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 34)
            HStack {
                Menu {
                    Picker("Voice", selection: $conversation.selectedVoice) {
                        ForEach(Voice.allCases) { voice in Text(voice.title).tag(voice) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Palette.accent.opacity(0.6)).frame(width: 5, height: 5)
                        Text(conversation.selectedVoice.title + " voice")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(conversation.phase.isWorking)
                .accessibilityLabel("Voice: \(conversation.selectedVoice.title)")
                .accessibilityIdentifier("voiceMenu")
                Spacer()
                Button { conversation.muted.toggle() } label: {
                    Image(systemName: conversation.muted ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 13)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                .accessibilityLabel(conversation.muted ? "Unmute voice replies" : "Mute voice replies")
                .accessibilityIdentifier("muteButton")
                .help(conversation.muted ? "Unmute voice replies" : "Mute voice replies")
            }
            .padding(.top, 15).padding(.bottom, 26)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.panel.opacity(0.5))
    }

    private var microphoneTitle: String {
        switch conversation.phase {
        case .listening: "Send what I said"
        case .thinking, .speaking: "Interrupt & speak"
        case .requestingMicrophone: "Opening microphone…"
        case .finishing: "Finishing…"
        default: "Start talking"
        }
    }
}

private struct ConversationPanel: View {
    @Bindable var conversation: Conversation
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversation").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("New", systemImage: "square.and.pencil", action: conversation.clear)
                    .font(.system(size: 11)).buttonStyle(.plain)
                    .foregroundStyle(Palette.secondary)
                    .disabled(conversation.phase == .preparing)
                    .help("Clear this conversation and start fresh. ⌘N")
                    .accessibilityIdentifier("newConversationButton")
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
            if let issue = conversation.languageIssue ?? conversation.issue ?? conversation.microphoneIssue {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").padding(.top, 2)
                    Text(issue).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if conversation.canDownloadSpeech && conversation.languageIssue == nil {
                        Button(conversation.downloadingSpeech ? "Downloading…" : "Download English") {
                            Task { await conversation.downloadSpeechAssets() }
                        }
                        .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                        .disabled(conversation.downloadingSpeech)
                        .help("Download Apple’s English speech assets. Internet is needed once; conversations then work offline.")
                    } else {
                        Button("Retry") { Task { await conversation.refreshAvailability() } }
                            .font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Palette.accent).padding(14)
                .background(Palette.accent.opacity(0.07), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 28).padding(.bottom, 8)
                .accessibilityIdentifier("statusNotice")
            }
            if conversation.messages.isEmpty && conversation.liveTranscript.isEmpty {
                welcome
            } else {
                transcript
            }
            composer
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 25)
            Image(systemName: "quote.opening").font(.system(size: 29, weight: .light))
                .foregroundStyle(Palette.accent.opacity(0.75)).padding(.bottom, 18)
            Text("Where shall we start?")
                .font(.system(size: 30, weight: .regular, design: .serif)).tracking(-0.8)
            Text("A half-formed idea, a question, or just your day.\nYou don’t need the perfect words.")
                .font(.system(size: 13)).lineSpacing(6)
                .foregroundStyle(Palette.secondary).padding(.top, 12)
            VStack(spacing: 9) {
                suggestion("Think it through", detail: "Untangle an idea together", symbol: "sparkle",
                           prompt: "I have an idea I’d like to think through. Can you help me explore it?")
                suggestion("Make something", detail: "Find a fresh starting point", symbol: "pencil.tip.crop.circle",
                           prompt: "Let’s come up with a creative idea for a small weekend project.")
                suggestion("Find the words", detail: "Say what you mean, simply", symbol: "text.bubble",
                           prompt: "Help me find the words for a thoughtful thank-you message.")
            }
            .padding(.top, 28)
            Spacer(minLength: 28)
        }
        .padding(.horizontal, 42).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestion(_ title: String, detail: String, symbol: String, prompt: String) -> some View {
        Button { conversation.suggest(prompt) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .light))
                    .foregroundStyle(Palette.accent).frame(width: 23)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(Palette.panel, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(conversation.phase != .idle || conversation.languageIssue != nil)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(conversation.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if !conversation.liveTranscript.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("LISTENING", systemImage: "waveform")
                                .font(.system(size: 9, weight: .semibold)).tracking(1.5)
                                .foregroundStyle(Palette.accent)
                            Text(conversation.liveTranscript).font(.system(size: 15)).lineSpacing(6)
                                .foregroundStyle(Palette.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 32).padding(.vertical, 18)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: conversation.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.liveTranscript) { proxy.scrollTo("bottom", anchor: .bottom) }
            .accessibilityIdentifier("transcript")
        }
    }

    private var composer: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Or put it into words…", text: $conversation.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .lineLimit(1...4).padding(.vertical, 10)
                    .focused($composerFocused)
                    .onSubmit { conversation.sendDraft() }
                    .accessibilityLabel("Message")
                    .accessibilityIdentifier("messageInput")
                Button(action: conversation.sendDraft) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(conversation.canSend ? .white : Palette.secondary)
                        .frame(width: 34, height: 34)
                        .background(conversation.canSend ? Palette.accent : Palette.line, in: .circle)
                }
                .buttonStyle(.plain).disabled(!conversation.canSend)
                .accessibilityLabel("Send message").accessibilityIdentifier("sendButton")
            }
            .padding(10).padding(.leading, 6)
            .background(Palette.panel, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(composerFocused ? Palette.accent.opacity(0.45) : Palette.line, lineWidth: 1))
            if conversation.draft.count > conversation.maximumMessageLength {
                Text("\(conversation.draft.count)/\(conversation.maximumMessageLength) characters · Please shorten your message")
                    .font(.system(size: 10)).foregroundStyle(.red)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "lock").font(.system(size: 9))
                    Text("Only here. Only yours.")
                    Text("·").padding(.horizontal, 2)
                    Text("AI can make mistakes.")
                }
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 16)
    }
}

private struct MessageRow: View {
    let message: Message
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if message.role == .assistant {
                    Image(systemName: "waveform").foregroundStyle(Palette.accent)
                }
                Text(message.role == .user ? "YOU" : "RONA").tracking(1.8)
                Spacer()
                if message.delivery == .interrupted { Text("Stopped").tracking(0) }
                if message.delivery == .failed { Text("Incomplete").tracking(0) }
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
            if message.text.isEmpty {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Thinking…").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }.padding(.vertical, 8)
            } else {
                Text(message.text).font(.system(size: 15)).lineSpacing(7)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(message.role == .assistant ? 18 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .assistant ? Palette.panel : .clear, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(message.role == .assistant ? "assistantMessage" : "userMessage")
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
        }
    }
}

private struct VoiceOrb: View {
    let active: Bool
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !active)) { context in
            let time = reduceMotion || !active ? 0 : context.date.timeIntervalSinceReferenceDate
            let drift = sin(time * 0.9)
            ZStack {
                Ellipse().fill(Color.purple.opacity(0.1)).frame(width: 138, height: 15)
                    .blur(radius: 15).offset(y: 91)
                Circle().stroke(Palette.accent.opacity(0.06), lineWidth: 1).frame(width: 204, height: 204)
                Circle().stroke(Palette.accent.opacity(0.08), lineWidth: 1).frame(width: 186, height: 186)
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(red: 0.81, green: 0.83, blue: 1), Color(red: 0.54, green: 0.42, blue: 0.86), Color(red: 0.36, green: 0.28, blue: 0.67)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(RadialGradient(colors: [Color(red: 0.56, green: 0.86, blue: 0.87), .clear],
                        center: UnitPoint(x: 0.15, y: 0.6 + drift * 0.05), startRadius: 0, endRadius: 135))
                    Circle().fill(RadialGradient(colors: [Color(red: 0.94, green: 0.81, blue: 0.96), .clear],
                        center: UnitPoint(x: 0.65, y: 0.15), startRadius: 0, endRadius: 125))
                    Circle().fill(RadialGradient(colors: [Color(red: 0.37, green: 0.22, blue: 0.69).opacity(0.7), .clear],
                        center: .bottomTrailing, startRadius: 0, endRadius: 135))
                    Canvas { graphics, size in
                        for index in 0..<29 {
                            let x = Double(index) / 28
                            let envelope = pow(sin(x * .pi), 1.4)
                            let motion = active ? (sin(time * 2.4 + x * 16) + 1) * 0.4 : 0.3
                            let height = 3 + envelope * (13 + motion * 17 + Double(level) * 55)
                            let rect = CGRect(x: x * 111 + 27, y: (size.height - height) / 2, width: 2, height: height)
                            graphics.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.65)))
                        }
                    }
                    Circle().stroke(.white.opacity(0.3), lineWidth: 1)
                }
                .frame(width: 166, height: 166).clipShape(.circle)
                .shadow(color: Palette.accent.opacity(0.16), radius: 18, y: 10)
                .scaleEffect(active && !reduceMotion ? 1 + drift * 0.025 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
