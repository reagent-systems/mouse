import SwiftUI

/// The Agent container (kind 6): a coding agent working on the ring's workspace.
///
/// Laid out the way the reference is: the exchange scrolls above, a follow-up field with a
/// microphone sits at the bottom, and the status line under it carries the workspace and the
/// agent picker. Vertical scroll and taps only, per the gesture law — the horizontal drag
/// belongs to the shell.
struct AgentContainerView: View {
    var deck: CarouselDeck?

    @State private var session = AgentSession()
    @State private var dictation = Dictation()
    @State private var speech = Speech()
    /// The current turn was SPOKEN, so its answer is spoken back and the microphone reopens
    /// after — a conversation, not a form. A typed turn stays silent.
    @State private var voiceTurn = false
    @State private var draft = ""
    @State private var pickerOpen = false
    @State private var settings = AgentSettings.shared
    @State private var setupDraft = ""
    @State private var addressDraft = ""
    @FocusState private var inputFocused: Bool
    @FocusState private var addressFocused: Bool
    @FocusState private var setupFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(session.agent.name.lowercased()) on \(deck?.workspace?.repoFullName ?? "no project")")
                .font(.custom(AppFont.asciiName, size: 11))
                .opacity(0.55)
                .lineLimit(1)
                .truncationMode(.middle)
            Color.clear.frame(height: 12)
            if session.loggingIn { loginScreen } else { exchange }
            Spacer(minLength: 0)
            if let problem = session.problem ?? dictation.problem {
                Text(problem)
                    .font(.custom(AppFont.asciiName, size: 11))
                    .opacity(0.85)
                    .padding(.bottom, 6)
            }
            if pickerOpen { picker }
            // A blocked agent does not ask for setup. Hermes needs a gateway address, but
            // nothing here can use one yet, and a field that collects a value the app ignores is
            // worse than no field — it reads as "configure me and I will work".
            // The address asks on its own terms, not behind the key. Gating it on the key being
            // empty meant it could never be reached once a key was saved — and a keychain entry
            // survives deleting the app, so "reinstall to fix it" does not work either. Submit an
            // address, even the default one, and the row goes.
            if session.agent.endpointVariable != nil, session.agent.blocked == nil,
               !session.loggingIn, settings.address(for: session.agent).isEmpty {
                addressField
            }
            // The ways in, all the agent's own: its sign-in or setup flow, and/or its key.
            // Any one satisfies `authenticated` and the rows go.
            if session.agent.blocked == nil, !session.loggingIn, !session.authenticated {
                if session.agent.login != nil { loginRow }
                if let setting = session.agent.setting { setup(setting) }
            }
            if let blocked = session.agent.blocked {
                Text(blocked)
                    .font(.custom(AppFont.asciiName, size: 10))
                    .opacity(0.4)
                    .padding(.bottom, 8)
            }
            input
            statusLine
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .onAppear { session.attach(root: deck?.workspace?.root) }
        .onChange(of: deck?.workspace?.root) { _, root in session.attach(root: root) }
        // Hands-free: the speaker stopped, the words go. No tap between saying and asking.
        .onChange(of: dictation.finished) { _, finished in
            guard finished else { return }
            let spoken = dictation.take()
            guard !spoken.isEmpty else { return }
            draft = draft.isEmpty ? spoken : draft + " " + spoken
            voiceTurn = true
            send()
        }
        // The answer, spoken as it streams: every delta feeds the synthesizer, which speaks
        // each sentence the moment it completes. The whole is flushed when the turn ends.
        .onChange(of: session.messages.last?.text) { _, text in
            guard voiceTurn, let text, session.messages.last?.author == .agent else { return }
            speech.feed(text)
        }
        .onChange(of: session.working) { _, working in
            guard voiceTurn, !working else { return }
            speech.finish()
            // Nothing to say (a problem, or a silent agent): hand the microphone back now.
            if !speech.speaking { Task { await dictation.start() } }
        }
        // Spoken answer done: listen for the reply. Six seconds of silence gives the mic back.
        .onChange(of: speech.speaking) { was, speaking in
            guard voiceTurn, was, !speaking, !session.working else { return }
            Task { await dictation.start() }
        }
        // The microphone closed on silence with nothing said: the conversation is over.
        .onChange(of: dictation.heardNothing) { _, nothing in
            if nothing { voiceTurn = false }
        }
    }

    // MARK: - The exchange

    private var exchange: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { message in
                        row(message).id(message.id)
                    }
                    if session.working {
                        ThinkingOrbLabel(state: .working, text: "working…")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ message: AgentSession.Message) -> some View {
        switch message.author {
        case .you:
            Text(message.text)
                .font(.custom(AppFont.asciiName, size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .agent:
            Text(message.text)
                .font(.custom(AppFont.asciiName, size: 13))
                .textSelection(.enabled)
        case .note:
            Text(message.text)
                .font(.custom(AppFont.asciiName, size: 10))
                .opacity(0.4)
        }
    }

    // MARK: - Input

    private var input: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft, axis: .vertical)
                .font(.custom(AppFont.asciiName, size: 13))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                // While a program owns the terminal the field is its stdin: a URL, a key, a
                // menu number — sentence-casing and autocorrect would rewrite them.
                .textInputAutocapitalization(session.loggingIn ? .never : .sentences)
                .autocorrectionDisabled(session.loggingIn)
            // The orb IS the microphone. It already had a listening state and it already sits
            // where the reference puts it, so a separate glyph beside it was two things saying
            // one thing. Tapping starts dictation and the orb picks up; tapping again stops it.
            // It fills the field rather than sending: dictation misreads identifiers, and a
            // prompt you cannot correct before it runs is worse than typing it.
            Button {
                Task { await toggleDictation() }
            } label: {
                ThinkingOrb(state: dictation.listening ? .listening
                            : speech.speaking ? .working : .idle, size: 20)
                    .frame(width: 32, height: 32)
                    .opacity(dictation.available ? 1 : 0.3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!dictation.available)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(draft.isEmpty ? 0.25 : 0.9))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A bare Enter is an answer to a program ("keep the default"), so the arrow stays
            // live on an empty field while one is running.
            .disabled((draft.isEmpty && !session.loggingIn) || session.working)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Text("address")
                .font(.custom(AppFont.asciiName, size: 10))
                .opacity(0.4)
            TextField("model endpoint (host[:port])", text: $addressDraft)
                .font(.custom(AppFont.asciiName, size: 12))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .focused($addressFocused)
                // Saved on return AND on tapping away: on a phone, leaving a field is how
                // most people finish it, and a value that quietly evaporates on blur is a
                // setting that never sticks.
                .onSubmit { settings.setAddress(addressDraft, for: session.agent) }
                .onChange(of: addressFocused) { was, is_ in
                    if was, !is_, !addressDraft.isEmpty {
                        settings.setAddress(addressDraft, for: session.agent)
                    }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 6)
        .onAppear { addressDraft = settings.address(for: session.agent) }
        .onChange(of: session.agent.id) { _, _ in
            addressDraft = settings.address(for: session.agent)
        }
    }

    /// The one field an agent needs before it can answer, shown only while it is empty. Saved
    /// on submit and not asked again — a key retyped every launch is a container nobody opens.
    private func setup(_ setting: CodingAgent.Setting) -> some View {
        HStack(spacing: 8) {
            Text(setting.name)
                .font(.custom(AppFont.asciiName, size: 10))
                .opacity(0.4)
            Group {
                if setting.secret {
                    SecureField(setting.placeholder, text: $setupDraft)
                } else {
                    TextField(setting.placeholder, text: $setupDraft)
                }
            }
            .font(.custom(AppFont.asciiName, size: 12))
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($setupFocused)
            .onSubmit { commitSetup() }
            // The same blur rule as the address: finished is finished, whether the finger
            // found return or the next field.
            .onChange(of: setupFocused) { was, is_ in
                if was, !is_, !setupDraft.isEmpty { commitSetup() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 8)
    }

    private func commitSetup() {
        // Commit the address too: someone who fills both fields and finishes once should not
        // silently lose the one they did not submit.
        if session.agent.embedded || session.agent.endpointVariable != nil, !addressDraft.isEmpty {
            settings.setAddress(addressDraft, for: session.agent)
        }
        settings.set(setupDraft, for: session.agent)
        setupDraft = ""
    }

    // MARK: - Sign-in, the agent's own

    /// Starts the agent's documented sign-in program on the terminal screen, in here.
    private var loginRow: some View {
        Button {
            Task { await session.login() }
        } label: {
            HStack(spacing: 8) {
                Text(session.agent.loginTitle ?? "sign in")
                    .font(.custom(AppFont.asciiName, size: 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    /// The sign-in program's screen, where the exchange normally is. The input field below
    /// keeps working — while a program owns the terminal, sending feeds it the line.
    @ViewBuilder
    private var loginScreen: some View {
        if let terminal = session.terminal {
            VStack(alignment: .leading, spacing: 8) {
                // The Terminal container's key row, up top, unchanged: up/down/left/right,
                // esc, tab, canc. An agent's own wizard or menu wants the same keys here
                // that it would want there.
                TerminalKeyStrip(session: terminal)
                // The program's own menu, mirrored: when the screen shows a numbered menu
                // (or a [Y/n] question), each visible option becomes a chip that TYPES its
                // number and Enter — the same answer, one tap instead of three. Read from
                // the grid, so it is whatever the program actually presented, and gone the
                // moment the program moves on. The chip matching what sits in the input
                // field lights up, so the field and the menu agree before send.
                // A fixed slot whether or not a menu is showing: the rail coming and going
                // must not resize the grid mid-program — the reflow scrambled the very
                // prompt row the rail is parsed from.
                Group {
                    if let menu = screenMenu(terminal) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(menu.options) { option in
                                    menuChip(option, terminal: terminal)
                                }
                            }
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 30)
                // The grid, whichever kind of program this is: one that draws a screen
                // (claude's ink sign-in) and one that prints and asks (hermes's setup wizard)
                // both land on it — a prompt with no newline yet is on the grid and in no
                // transcript line, and the cooked-mode echo of what is being typed is there
                // too. It scrolls the way a terminal does.
                GeometryReader { geo in
                    TerminalScreenGrid(terminal: terminal)
                        .onAppear { applyGrid(geo.size, terminal: terminal) }
                        .onChange(of: geo.size) { _, size in applyGrid(size, terminal: terminal) }
                }
                HStack(spacing: 8) {
                    if let url = signInURL(terminal) {
                        Link(destination: url) {
                            Text("open \(url.host() ?? "the sign-in page")")
                                .font(.custom(AppFont.asciiName, size: 11))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.1),
                                            in: Capsule())
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        session.cancelLogin()
                    } label: {
                        Text("stop")
                            .font(.custom(AppFont.asciiName, size: 11))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.1), in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func applyGrid(_ size: CGSize, terminal: TerminalSession) {
        terminal.setGridSize(rows: Int(size.height / TerminalCellMetrics.height),
                             columns: Int(size.width / TerminalCellMetrics.width))
    }

    /// The sign-in URL as the program printed it — reassembled across hard-wrapped rows (a
    /// full-width row continues on the next) so the link carries the whole query string.
    private func signInURL(_ terminal: TerminalSession) -> URL? {
        _ = terminal.screenGeneration
        let screen = terminal.screen
        var joined = ""
        for row in 0..<screen.rows {
            let text = screen.text(row: row)
            joined += text
            if text.count < screen.columns { joined += "\n" }
        }
        guard let range = joined.range(of: #"https://\S+"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(joined[range]))
    }

    // MARK: - The program's menu, as chips

    /// One choice a running program printed: its number (or y/n), what it says, whether the
    /// program marked it as the default.
    private struct ScreenMenuOption: Identifiable {
        let id: String
        /// What tapping TYPES — "2", "y", "n". The chip is an input method, nothing more.
        let types: String
        let label: String
        let isDefault: Bool
    }

    private struct ScreenMenu {
        let options: [ScreenMenuOption]
    }

    /// Read the visible screen for a menu awaiting an answer. A prompt is the last non-empty
    /// row ending with `:`; `[Y/n]`/`[y/N]` becomes yes/no, and `(●) 12. Label` rows above a
    /// choice prompt become numbered chips. Wrapped continuation rows do not match the option
    /// shape and simply do not become chips — the full text is on the grid regardless.
    private func screenMenu(_ terminal: TerminalSession) -> ScreenMenu? {
        _ = terminal.screenGeneration
        let screen = terminal.screen
        var lastRow: String?
        var lastIndex = -1
        for row in stride(from: screen.rows - 1, through: 0, by: -1) {
            let text = screen.text(row: row).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { lastRow = text; lastIndex = row; break }
        }
        guard let prompt = lastRow, prompt.hasSuffix(":") || prompt.hasSuffix(": ") else { return nil }
        if prompt.contains("[Y/n]") || prompt.contains("[y/N]") {
            let yesDefault = prompt.contains("[Y/n]")
            return ScreenMenu(options: [
                ScreenMenuOption(id: "y", types: "y", label: "yes", isDefault: yesDefault),
                ScreenMenuOption(id: "n", types: "n", label: "no", isDefault: !yesDefault),
            ])
        }
        // The default the prompt names ("Choice [default 6]:"), if it names one.
        var promptDefault: Int?
        if let range = prompt.range(of: #"\[default (\d+)\]"#, options: .regularExpression) {
            promptDefault = Int(prompt[range].filter(\.isNumber))
        }
        var options: [ScreenMenuOption] = []
        for row in 0..<lastIndex {
            let text = screen.text(row: row)
            guard let match = text.range(of: #"^\s*(?:\([●○xX ]\)|\[[xX ]\]|[●○])?\s*(\d{1,3})\.\s+\S"#,
                                         options: .regularExpression) else { continue }
            let matched = String(text[match])
            let number = matched.filter(\.isNumber)
            guard let value = Int(number) else { continue }
            var label = String(text[match.upperBound...])
            label = (matched.suffix(1) + label).trimmingCharacters(in: .whitespaces)
            if label.count > 26 { label = String(label.prefix(25)) + "…" }
            let marked = matched.contains("●") || matched.lowercased().contains("x")
            options.append(ScreenMenuOption(id: "\(row)-\(value)", types: "\(value)",
                                            label: "\(value) \(label)",
                                            isDefault: marked || value == promptDefault))
        }
        // A menu, not a coincidence: one stray "1. " in prose is not a menu.
        guard options.count >= 2 else { return nil }
        return ScreenMenu(options: options)
    }

    private func menuChip(_ option: ScreenMenuOption, terminal: TerminalSession) -> some View {
        let typed = draft.trimmingCharacters(in: .whitespaces)
        let lit = typed == option.types && !typed.isEmpty
        return Button {
            draft = ""
            _ = terminal.sendPaste(option.types)
            _ = terminal.sendKey("\r")
        } label: {
            Text(option.label)
                .font(.custom(AppFont.asciiName, size: 11))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(lit ? 0.28 : option.isDefault ? 0.14 : 0.07),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Picker and status

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CodingAgent.all) { entry in
                Button {
                    session.agent = entry
                    pickerOpen = false
                } label: {
                    HStack(spacing: 8) {
                        Text(entry.name)
                            .font(.custom(AppFont.asciiName, size: 13))
                            .opacity(entry.blocked == nil ? 1 : 0.5)
                        Text(entry.runtime.rawValue)
                            .font(.custom(AppFont.asciiName, size: 10))
                            .opacity(0.4)
                        Spacer(minLength: 0)
                        // The agent's own setup or sign-in, reachable AGAIN from here once
                        // it has gone through — `hermes setup` is a thing people re-run, and
                        // a sign-in expires. The row below the chat only asks the first time.
                        if let title = entry.loginTitle, entry.blocked == nil {
                            Button {
                                session.agent = entry
                                pickerOpen = false
                                Task { await session.login() }
                            } label: {
                                Text(title)
                                    .font(.custom(AppFont.asciiName, size: 10))
                                    .opacity(0.55)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.white.opacity(0.08), in: Capsule())
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if entry.id == session.agent.id {
                            Text("•").font(.custom(AppFont.asciiName, size: 13))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let blocked = entry.blocked {
                    Text(blocked)
                        .font(.custom(AppFont.asciiName, size: 10))
                        .opacity(0.4)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            // The two numbers a voice agent is judged by, from the last turn: seconds to the
            // first word, and to the whole answer.
            if let latency = session.latency {
                Text(latency.firstWord.map { String(format: "%.1fs first word · %.1fs", $0, latency.whole) }
                     ?? String(format: "%.1fs", latency.whole))
                    .font(.custom(AppFont.asciiName, size: 10))
                    .opacity(0.4)
            }
            Spacer(minLength: 0)
            Button {
                pickerOpen.toggle()
            } label: {
                Text(session.agent.name)
                    .font(.custom(AppFont.asciiName, size: 10))
                    .opacity(0.55)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func send() {
        let text = draft
        draft = ""
        // While the sign-in program owns the terminal, the field feeds IT — pasted code,
        // then return — instead of starting a conversation turn.
        if session.loggingIn, let terminal = session.terminal, terminal.program != nil {
            if !text.isEmpty { _ = terminal.sendPaste(text) }
            _ = terminal.sendKey("\r")
            return
        }
        if voiceTurn { speech.begin() } else { speech.stop() }
        Task { await session.send(text) }
    }

    /// The orb: tap to talk; tap while talking to stop and SEND what was said — a second
    /// tap means "done", not "discard"; tap while the answer is being spoken to interrupt it
    /// and talk over it.
    private func toggleDictation() async {
        if dictation.listening {
            dictation.stop()
            let spoken = dictation.take()
            if !spoken.isEmpty {
                draft = draft.isEmpty ? spoken : draft + " " + spoken
                voiceTurn = true
                send()
            }
        } else {
            if speech.speaking { speech.stop() }
            voiceTurn = true
            await dictation.start()
        }
    }
}
