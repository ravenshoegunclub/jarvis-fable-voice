import Foundation
import AVFoundation
import Speech
import UIKit

/* ============================================================
   JARVIS ENGINE · the conversation, and the truth the Radial shows
     listening  → the iPad's own speech recognition (local, stays on-device)
     thinking   → Groq's real model does ALL the reasoning (14/11/2026 —
                  see CloudAI.swift/GroqBrain for why the on-device model
                  was dropped as the router)
     speaking   → ElevenLabs when configured, the built-in voice otherwise
   The Radial never guesses: it draws whatever `mode` says, and the
   blue pulse fires on each word the voice actually speaks.
   Privacy: nothing listens until the orb is tapped, and it goes back
   to sleep after a quiet spell or when told "that's all".
   ============================================================ */

enum JarvisMode {
    case asleep      // not listening; tap the orb to start
    case listening   // waiting for Carl to speak
    case thinking    // Groq is working
    case speaking    // the voice is talking
}

// Which model answers, switched by voice the same way Home Jarvis
// switches on the laptop (15/11/2026, Carl's call): cloud (Groq) stays the
// generalist, local (Apple's on-device model, LocalAI.swift) is Carl's
// own "me specialist" — personal tools come in a later pass. Carl sees
// and hears "Local Model" / "Cloud Model" (16/11/2026, backlog #46);
// the type keeps its old name, which he never sees.
enum Brain: String {
    case cloud, local
}

// One line of the iPad's own chat window (15/11/2026, #46 follow-on) —
// typed parity with the laptop's radial-float/chat.html feed.
struct ChatLine: Identifiable {
    enum Who: Equatable { case you, jarvis }
    let id = UUID()
    let who: Who
    let text: String
}

@MainActor
final class JarvisEngine: NSObject, ObservableObject {
    @Published private(set) var mode: JarvisMode = .asleep
    @Published private(set) var modeSince = Date()
    // Every launch starts on the Local Model (Carl, 16/11/2026).
    @Published private(set) var brain: Brain = .local
    @Published private(set) var heard = ""
    @Published private(set) var answer = ""
    @Published private(set) var problem = ""
    // The chat window's own transcript — every line either side has said,
    // regardless of whether it was spoken or typed (15/11/2026).
    @Published private(set) var chatLines: [ChatLine] = []
    @Published private(set) var hasVault = false
    @Published private(set) var hasSearchKey = false
    @Published private(set) var hasCloudAIKey = false
    @Published private(set) var hasCloudVoiceKey = false
    @Published private(set) var searching = false
    // Sitting out a short Groq rate-limit wait (15/11/2026) — shown as
    // "One moment, sir" rather than failing the question.
    @Published private(set) var pacing = false
    @Published private(set) var generatingImage = false
    @Published private(set) var generatedImage: UIImage?
    @Published private(set) var foundPhotos: [UIImage] = []
    // A real page shown in-app, never handed off to Safari — same
    // one-interface principle that killed the Gemini hand-off this
    // morning (14/11/2026, backlog #36).
    @Published private(set) var openWebPage: URL?
    // The chat window's voice bar (15/11/2026): mute and volume for
    // whichever voice is speaking, Daniel (ElevenLabs) or the iPad's own
    // fallback. Remembered between launches.
    @Published private(set) var voiceMuted = false
    @Published private(set) var voiceVolume: Float = 1

    // The real urls search_web found THIS turn — open_webpage may only
    // ever open one of these, never a url the model supplied from its
    // own memory. Reset at the start of every turn (14/11/2026).
    private var lastSearchURLs: [String] = []

    // Read every frame by the Radial; deliberately not @Published, so
    // they don't rebuild the whole screen sixty times a second.
    private(set) var lastWordAt = Date.distantPast
    private(set) var micLevel: Float = 0

    // Set by the Radial: called on every word the voice actually speaks.
    var onWord: (() -> Void)?

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var listenToken = 0
    private var listenStartedAt = Date.distantPast
    private var silenceTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    private let synth = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var pulseTimer: Timer?
    private var listenAfterSpeaking = false
    // A typed question never auto-opens the microphone afterwards — only
    // a voice-originated one does. Without this, a chat-only Carl who's
    // never granted mic permission would have the app silently try (and
    // fail) to start listening after every typed reply (15/11/2026).
    private var lastTurnByVoice = true
    // Local Jarvis's "can't read my notes" notice is said once per launch.
    private var warnedAboutNotes = false

    // The whole conversation, OpenAI chat-message shape, sent to Groq on
    // every turn — Groq itself is the one deciding whether to answer from
    // the notes below, search the web, draw a picture, or just answer.
    private var groqMessages: [[String: Any]] = []

    private static let vaultKey = "vaultBookmark"
    private static let brainKey = "activeBrain"
    private static let mutedKey = "voiceMuted"
    private static let volumeKey = "voiceVolume"
    private static let quickFactsFile = "Mobile Quick Facts.md"
    // The checked personal facts Local Jarvis may state about Carl. Read
    // by the LOCAL brain only, so it stays on this iPad and is never sent
    // to Groq (15/11/2026).
    private static let aboutCarlPath = ["06 - Personal", "About Carl.md"]
    private static let pauseBeforeAnswering: Duration = .seconds(1.4)
    private static let quietBeforeSleeping: Duration = .seconds(25)

    override init() {
        super.init()
        print("[Jarvis] JarvisCore, weather and websites version (16/11/2026)")
        synth.delegate = self
        hasVault = UserDefaults.standard.data(forKey: Self.vaultKey) != nil
        hasSearchKey = SearchKey.isSet
        hasCloudAIKey = CloudAIKey.isSet
        hasCloudVoiceKey = CloudVoiceKey.isSet
        voiceMuted = UserDefaults.standard.bool(forKey: Self.mutedKey)
        if UserDefaults.standard.object(forKey: Self.volumeKey) != nil {
            voiceVolume = UserDefaults.standard.float(forKey: Self.volumeKey)
        }
    }

    var statusLine: String {
        if !problem.isEmpty { return problem }
        switch mode {
        case .asleep:    return hasVault ? "Tap the orb to talk" : "Choose the Jarvis vault folder first"
        case .listening: return "Listening"
        case .thinking:
            if pacing { return "One moment, sir" }
            if searching { return "Searching the web" }
            if generatingImage { return "Drawing a picture" }
            return "Thinking"
        case .speaking:  return "Speaking"
        }
    }

    // MARK: - The brain switch

    private func switchBrain(to target: Brain) {
        guard target != brain else { return }
        brain = target
    }

    // Same phrases as Home Jarvis on the laptop (16/11/2026, backlog #46):
    // "switch to the cloud model", "go to the cloud model", "switch to the
    // local model", "go to the local model", "go local model". A switching
    // verb must lead, so a question about a model never switches. "modal",
    // "muddle" and "crowd" cover likely mishearings. The old "local/cloud
    // jarvis" and bare "go local/cloud" phrases are retired.
    private static func requestedBrain(_ text: String) -> Brain? {
        let t = text.lowercased()
        let lead = #"\b(switch to|switch over to|change to|go to|back to|use|switch|go),? (the |your |my )?"#
        let model = #" (model|modal|muddle|models)\b"#
        if t.range(of: lead + "local" + model, options: .regularExpression) != nil { return .local }
        if t.range(of: lead + "(cloud|crowd)" + model, options: .regularExpression) != nil { return .cloud }
        return nil
    }

    // MARK: - The orb

    func orbTapped() {
        if mode == .asleep {
            Task { await wake() }
        } else {
            goToSleep()
        }
    }

    private func wake() async {
        problem = ""
        guard hasVault else {
            problem = "Choose the Jarvis vault folder first"
            return
        }
        guard await permissionsGranted() else {
            problem = "I need the microphone and speech recognition. Allow them in Settings → Apps → Jarvis."
            return
        }
        startListening()
        armSleepTimer()
    }

    // Guards appendConversationDigest against writing the same exchange
    // twice — e.g. waking, saying nothing, and idling back to sleep on
    // an old answer that was already logged (14/11/2026, #40).
    private var lastDigestedAnswer: String?

    func goToSleep() {
        listenAfterSpeaking = false
        idleTask?.cancel(); idleTask = nil
        stopSpeaking()
        stopListening()
        setMode(.asleep)
        if !heard.isEmpty, !answer.isEmpty, answer != lastDigestedAnswer {
            lastDigestedAnswer = answer
            appendConversationDigest(question: heard, answer: answer)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Carl's own close control on the display pane. Deliberately NOT
    // called from goToSleep() any more (14/11/2026) — it was, briefly,
    // but that closed a picture out from under Carl just for going quiet
    // looking at it, since silence alone is enough to fall asleep. The
    // split-screen pane already keeps pictures clear of the settings
    // menu, so only this explicit close should ever clear one now.
    func clearDisplay() {
        generatedImage = nil
        foundPhotos = []
        openWebPage = nil
    }

    private func setMode(_ m: JarvisMode) {
        guard m != mode else { return }
        searching = false
        generatingImage = false
        mode = m
        modeSince = Date()
    }

    private func permissionsGranted() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    // If Carl says nothing for a while, stop listening: the mic is only
    // ever open while he's actually in a conversation.
    private func armSleepTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: JarvisEngine.quietBeforeSleeping)
            guard !Task.isCancelled, let self, self.mode == .listening, self.heard.isEmpty else { return }
            self.goToSleep()
        }
    }

    // MARK: - Listening

    private func startListening() {
        stopListening()
        heard = ""
        listenToken += 1
        listenStartedAt = Date()

        guard let recognizer, recognizer.isAvailable else {
            fail("Speech recognition isn't available right now.")
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            fail("Couldn't open the microphone.")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        // Words the recogniser should expect, so "BOM" isn't heard as
        // "bomb" (16/11/2026). Mishearings that still slip through are
        // corrected in fixMishearings(_:).
        req.contextualStrings = Self.speechHints
        request = req

        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                         block: Self.micTap(request: req, engine: self))
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            fail("Couldn't start listening.")
            return
        }

        recognition = recognizer.recognitionTask(with: req,
                                                 resultHandler: Self.recognitionHandler(engine: self, token: listenToken))
        setMode(.listening)
    }

    private func stopListening() {
        silenceTask?.cancel(); silenceTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
        micLevel = 0
    }

    // Shared by goToSleep() and a typed message arriving while Jarvis is
    // already mid-reply (15/11/2026) — cuts off whichever voice is live.
    private func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if let player = audioPlayer, player.isPlaying { player.stop() }
        pulseTimer?.invalidate(); pulseTimer = nil
    }

    // MARK: - Mute and volume (the chat window's voice bar)

    // Muting plays at volume 0 rather than skipping the speech, so the
    // orb, timing and chat all behave exactly as if Jarvis had spoken —
    // same rule as the laptop's own mute.
    private var effectiveVolume: Float { voiceMuted ? 0 : voiceVolume }

    // Daniel's voice changes mid-sentence; the iPad's fallback voice can't
    // (an utterance's volume is fixed once it starts), so it catches up on
    // the next line.
    func toggleMute() {
        voiceMuted.toggle()
        UserDefaults.standard.set(voiceMuted, forKey: Self.mutedKey)
        audioPlayer?.volume = effectiveVolume
    }

    func setVolume(_ level: Float) {
        voiceVolume = min(max(level, 0), 1)
        UserDefaults.standard.set(voiceVolume, forKey: Self.volumeKey)
        audioPlayer?.volume = effectiveVolume
    }

    private func fail(_ message: String) {
        problem = message
        goToSleep()
    }

    // These two run on background threads, so they're built outside the
    // main actor and hand their results back to it explicitly.
    nonisolated private static func micTap(request: SFSpeechAudioBufferRecognitionRequest,
                                           engine: JarvisEngine) -> AVAudioNodeTapBlock {
        return { [weak engine] buffer, _ in
            request.append(buffer)
            let level = loudness(of: buffer)
            guard let engine else { return }
            Task { @MainActor in engine.micLevel = level }
        }
    }

    nonisolated private static func recognitionHandler(engine: JarvisEngine, token: Int)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak engine] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = result == nil && error != nil
            guard let engine else { return }
            Task { @MainActor in
                engine.recognised(text: text, isFinal: isFinal, failed: failed, token: token)
            }
        }
    }

    private func recognised(text: String?, isFinal: Bool, failed: Bool, token: Int) {
        guard token == listenToken, mode == .listening else { return }
        if let text {
            heard = text
            if isFinal { questionFinished() } else { waitForPause() }
        } else if failed {
            if !heard.isEmpty {
                questionFinished()
            } else if Date().timeIntervalSince(listenStartedAt) < 2 {
                // Failing straight away means something's genuinely wrong;
                // don't spin restarting it.
                fail("Speech recognition stopped working. Tap the orb to try again.")
            } else {
                // It gave up after a quiet spell: start a fresh one and keep waiting.
                startListening()
            }
        }
    }

    // Each new word restarts the clock; a short pause means Carl's done.
    private func waitForPause() {
        silenceTask?.cancel()
        let token = listenToken
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: JarvisEngine.pauseBeforeAnswering)
            guard !Task.isCancelled, let self, self.listenToken == token else { return }
            self.questionFinished()
        }
    }

    private func questionFinished() {
        guard mode == .listening else { return }
        let question = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        idleTask?.cancel(); idleTask = nil
        stopListening()
        lastTurnByVoice = true
        handleQuestion(question)
    }

    // The chat window's entry point (15/11/2026, #46 follow-on) — the same
    // path speech takes from questionFinished() onward, minus the
    // microphone bookkeeping, so typing works whether Jarvis is asleep,
    // listening, or already mid-reply to something else.
    func submitTyped(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if mode == .listening { stopListening() }
        if mode == .speaking { stopSpeaking() }
        idleTask?.cancel(); idleTask = nil
        heard = question
        lastTurnByVoice = false
        handleQuestion(question)
    }

    private func handleQuestion(_ rawQuestion: String) {
        let question = Self.fixMishearings(rawQuestion)
        if question != rawQuestion { heard = question }
        chatLines.append(ChatLine(who: .you, text: question))
        setMode(.thinking)
        if Self.isGoodbye(question) {
            answer = "Very good, sir."
            say(answer, thenListen: false)
            return
        }
        if let target = Self.requestedBrain(question) {
            switchBrain(to: target)
            answer = "Switched to the \(target == .local ? "Local" : "Cloud") Model, sir."
            say(answer, thenListen: true)
            return
        }
        // Handled by the app itself, for both models (16/11/2026): the
        // real BOM forecast page, or a site's own home page, in the
        // display pane. Not left to a model's judgement.
        if let place = Self.weatherPlace(in: question) {
            Task { await showWeather(at: place, question: question) }
            return
        }
        if let site = Self.websiteName(in: question) {
            Task { await showWebsite(named: site) }
            return
        }
        Task { await think(about: question) }
    }

    private static func isGoodbye(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["that's all", "that is all", "goodbye", "good bye", "go to sleep", "stop listening"]
            .contains { t.contains($0) }
    }

    nonisolated private static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 12)
    }

    // MARK: - Thinking

    private func think(about question: String) async {
        switch brain {
        case .cloud: await thinkCloud(about: question)
        case .local: await thinkLocal(about: question)
        }
    }

    // Carl's "me specialist" (15/11/2026): on-device, no network call, no
    // tools yet — personal tools (files, calendar, shopping list, basic
    // online lookups) come in a later pass, see LocalAI.swift.
    private func thinkLocal(about question: String) async {
        let about = readAboutCarl()
        let instructions = Self.localSystemPrompt(facts: readQuickFacts(), about: about)
        var reply = await LocalBrain.reply(to: question, instructions: instructions)
        // The app says this itself, once per launch, rather than trusting
        // a small model to report it (15/11/2026).
        if about == nil, !warnedAboutNotes {
            warnedAboutNotes = true
            reply = "I can't read my notes about you at the moment, sir. " + reply
        }
        // Carl may have tapped the orb to stop while it was thinking.
        guard mode == .thinking else { return }
        answer = reply
        say(reply, thenListen: true)
    }

    // Rewritten 15/11/2026 for what a small on-device model does well:
    // short, with Carl's facts first and no ready-made sentence to parrot.
    // Two earlier wordings quoted a fallback line ("I don't have that on
    // record, sir") and the model gave it to every question. The
    // recent-conversation headlines are left out too: technical noise at
    // this size. The Cloud Model still gets them.
    private static func localSystemPrompt(facts: String, about: String?) -> String {
        let today = Date().formatted(date: .complete, time: .shortened)
        let aboutBlock = about ?? "(No facts are available right now.)"
        return """
        You are Mobile Jarvis, Carl's personal assistant, running on your Local Model on this iPad \
        and speaking out loud. Answer in one to three short sentences of plain British English, with \
        no lists, no symbols and no web addresses. Call him sir now and then.

        These are the facts you know about Carl:
        \(aboutBlock)

        Use these facts when Carl asks about himself. If he asks what you know about him, tell him \
        several of them. If he asks where he lives, give his address. If he asks for a personal \
        detail that is not among these facts, tell him you don't know that yet; do not make one up.

        You can chat and answer general questions from your own knowledge. You run on this iPad \
        itself and have no tools yet, so you cannot search the web, show pictures or check his \
        calendar. If he asks for one of those, suggest he switches to the Cloud Model.

        The current date and time is \(today).

        What is open on the Jarvis project at the moment:
        \(facts)
        """
    }

    // Carl's generalist (Groq cloud, unchanged from 14/11/2026 other than
    // being one of two models now rather than the only one).
    private func thinkCloud(about question: String) async {
        if groqMessages.isEmpty {
            groqMessages = [["role": "system", "content": Self.groqSystemPrompt(
                facts: readQuickFacts(), recent: readRecentConversations())]]
        }
        trimGroqHistory()
        groqMessages.append(["role": "user", "content": question])
        let turnStart = groqMessages.count
        // Valid only for THIS turn's open_webpage call (14/11/2026, #36).
        lastSearchURLs = []

        var imageData: Data?
        var photosData: [Data] = []
        var webPageURL: URL?
        var reply = "Sorry, I couldn't work that one out."
        do {
            // Up to 3 round trips: a tool call, its result fed back, and
            // the model's real answer — enough for one or two tool calls
            // in the same turn without looping forever on a confused model.
            roundTrip: for _ in 0..<3 {
                let json = try await GroqBrain.chat(messages: groqMessages,
                                                    onWait: { self.pacing = $0 })
                guard let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any] else {
                    break
                }
                groqMessages.append(message)
                if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    for call in toolCalls {
                        await handleToolCall(call, imageData: &imageData, photosData: &photosData,
                                             webPageURL: &webPageURL)
                    }
                    continue roundTrip
                }
                if let content = message["content"] as? String, !content.isEmpty {
                    reply = content
                }
                break
            }
        } catch {
            reply = (error as NSError).localizedDescription
        }
        pacing = false
        shrinkToolResults(from: turnStart)
        // Carl may have tapped the orb to stop while it was thinking.
        guard mode == .thinking else { return }
        if let webPageURL {
            openWebPage = webPageURL
            generatedImage = nil
            foundPhotos = []
        } else if let imageData, let image = UIImage(data: imageData) {
            generatedImage = image
            foundPhotos = []
            openWebPage = nil
        } else if !photosData.isEmpty {
            foundPhotos = photosData.compactMap { UIImage(data: $0) }
            generatedImage = nil
            openWebPage = nil
        }
        answer = reply
        say(reply, thenListen: true)
    }

    /// Runs one function call Groq asked for, appending its result as a
    /// `tool` message so the next request can see what happened.
    private func handleToolCall(_ call: [String: Any], imageData: inout Data?, photosData: inout [Data],
                                webPageURL: inout URL?) async {
        guard let id = call["id"] as? String,
              let function = call["function"] as? [String: Any],
              let name = function["name"] as? String else { return }
        let argsString = function["arguments"] as? String ?? "{}"
        let args = (try? JSONSerialization.jsonObject(with: Data(argsString.utf8))) as? [String: Any] ?? [:]
        var result = "Unknown tool."
        switch name {
        case "search_web":
            searching = true
            let (text, urls) = await WebSearch.run(query: args["query"] as? String ?? "")
            lastSearchURLs = urls
            result = text
            searching = false
        case "open_webpage":
            let requested = args["url"] as? String ?? ""
            if lastSearchURLs.contains(requested), let url = URL(string: requested) {
                webPageURL = url
                result = "The page is now open on Carl's own screen. You have not seen it and cannot describe its content — say only something brief like \"Here you go, sir\"."
            } else {
                result = "Refused: that url didn't come from this turn's search_web results. Call search_web first, then pass one of ITS exact result urls — never one from your own memory."
            }
        case "generate_image":
            generatingImage = true
            if let data = await ImageGen.run(description: args["description"] as? String ?? "") {
                imageData = data
                result = "A fictional picture is now showing on Carl's own screen. You have not seen it and cannot describe its content — say only something brief like \"Here you go, sir\"."
            } else {
                result = "The image service failed to return a picture. Tell Carl plainly it failed — do not describe or guess at any image."
            }
            generatingImage = false
        case "find_photos":
            generatingImage = true
            let (text, images) = await WebSearch.findPhotos(query: args["query"] as? String ?? "")
            photosData = images
            result = text
            generatingImage = false
        default:
            break
        }
        groqMessages.append(["role": "tool", "tool_call_id": id, "content": result])
    }

    // MARK: - Keeping each Groq request light (15/11/2026)
    //
    // Groq's free plan allows 8,000 tokens a minute, and groqMessages was
    // never trimmed: every past question, answer and full search result
    // was re-sent with every request, so requests grew from about 2,100
    // tokens in the morning to about 3,500 by evening (Carl's Groq log) and
    // one searching question could fill a minute on its own. Cached
    // tokens are free against the limit (Groq's docs), and caching only
    // works while the START of each request stays the same — so history
    // is cut back in one occasional chunk, not one message every turn.

    private static let historyBudget = 12_000   // characters, past the system prompt
    private static let turnsKept = 3

    private func trimGroqHistory() {
        guard groqMessages.count > 1 else { return }
        let size = groqMessages.dropFirst().reduce(0) { total, message in
            total + ((try? JSONSerialization.data(withJSONObject: message))?.count ?? 0)
        }
        guard size > Self.historyBudget else { return }
        // Cut only at a question, so no answer or tool result is left
        // without the turn it belongs to.
        let questions = groqMessages.indices.filter {
            $0 > 0 && (groqMessages[$0]["role"] as? String) == "user"
        }
        guard questions.count > Self.turnsKept else { return }
        let cut = questions[questions.count - Self.turnsKept]
        groqMessages = [groqMessages[0]] + groqMessages[cut...]
    }

    // A search's full results matter only for the answer they fed. Once
    // the turn's over, a one-line stand-in keeps the history coherent
    // without re-sending them with every later request.
    private func shrinkToolResults(from start: Int) {
        guard start <= groqMessages.count else { return }
        for i in start..<groqMessages.count where (groqMessages[i]["role"] as? String) == "tool" {
            if let content = groqMessages[i]["content"] as? String, content.count > 300 {
                groqMessages[i]["content"] = "(Results used for the answer above; trimmed to save space.)"
            }
        }
    }

    private static func groqSystemPrompt(facts: String, recent: String?) -> String {
        let today = Date().formatted(date: .complete, time: .shortened)
        // One plain literal, not a chain of "+": a long chain inside this
        // closure was too slow for Swift's type-checker (build failure,
        // 16/11/2026).
        let recentHeader: String = "\n\nRECENT CONVERSATIONS (headlines only, from Home Jarvis on the laptop and the Coding Brain too — not the full detail; read Carl's notes yourself if he brings one up. Older lines may say Home Brain, Big Brain, Mobile Brain, Local Jarvis or Cloud Jarvis: those are the old names for the Local Model and the Cloud Model, so always say the new names):\n"
        let recentBlock: String = recent.map { recentHeader + $0 } ?? ""
        return """
        You are Mobile Jarvis, Carl's personal assistant, running on your Cloud Model (Groq) and \
        speaking out loud. Carl lives near Atherton in \
        Far North Queensland, Australia, and prices are in Australian dollars. Answer in one to three \
        short sentences of plain British English: no lists, no markdown, no symbols, and never read out \
        web addresses.
        For questions about Carl's own work and plans, use only the notes below.
        For anything that needs current or local facts (news, sport, prices, businesses, anything that \
        may have changed), call search_web first, then answer from what it found and briefly say where \
        it came from.
        For a picture request, tell real from fictional apart, the same way a genuinely capable model \
        should: "create/make/draw/paint/imagine" a picture means call generate_image, which fabricates \
        something that doesn't exist. "Get me/find me/show me/are there (any) pictures or photos of" a \
        real place, person, or thing means call find_photos instead, which searches for real existing \
        photos — never say something doesn't exist or fall back to generating one just because a real \
        search came up thin; report what was actually found. You will never see either result yourself, \
        so afterwards say only something brief, like "Here you go, sir", and nothing about what it shows.
        When Carl asks you to "bring up", "show me", or "open" a specific website or page — rather than \
        just wanting a spoken answer — call search_web first, then call open_webpage with one of ITS \
        exact result urls so the real page opens right there on his screen. NEVER pass open_webpage a \
        url from your own memory or training, even one you are confident about: it will be refused, \
        because an address you only think you remember is exactly the kind of thing you can get \
        confidently wrong. You will never see the page yourself, so afterwards say only something \
        brief, like "Here you go, sir".
        If neither the notes, the search, nor a picture answer it, use your own knowledge and \
        reasoning — you are a genuinely capable model, not a small one, so answer properly rather than \
        refusing. Only say you don't know if you truly don't.
        The current date and time is \(today).

        NOTES:
        \(facts)\(recentBlock)
        """
    }

    func setSearchKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasSearchKey = SearchKey.save(trimmed)
        if !hasSearchKey { problem = "Couldn't save the search key. Try again." }
    }

    func setCloudAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasCloudAIKey = CloudAIKey.save(trimmed)
        if !hasCloudAIKey { problem = "Couldn't save the cloud AI key. Try again." }
    }

    func setCloudVoiceKey(_ key: String, voiceID: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedVoiceID.isEmpty else { return }
        hasCloudVoiceKey = CloudVoiceKey.save(key: trimmedKey, voiceID: trimmedVoiceID)
        if !hasCloudVoiceKey { problem = "Couldn't save the cloud voice key. Try again." }
    }

    // MARK: - The vault

    func setVault(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        // iCloud may hold a not-yet-downloaded placeholder (".name.icloud") instead.
        let fm = FileManager.default
        let real = url.appendingPathComponent(Self.quickFactsFile).path
        let placeholder = url.appendingPathComponent("." + Self.quickFactsFile + ".icloud").path
        guard fm.fileExists(atPath: real) || fm.fileExists(atPath: placeholder) else {
            problem = "That folder has no \(Self.quickFactsFile). Pick the Jarvis folder itself."
            return
        }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            problem = "Couldn't remember that folder. Try picking it again."
            return
        }
        UserDefaults.standard.set(data, forKey: Self.vaultKey)
        hasVault = true
        problem = ""
        groqMessages = []
        LocalBrain.reset()
    }

    private func vaultFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.vaultKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.vaultKey)
        }
        return url
    }

    // Read through a file coordinator so iCloud downloads the latest copy first.
    private func readQuickFacts() -> String {
        guard let folder = vaultFolder() else { return "(No notes: the vault folder hasn't been chosen.)" }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(Self.quickFactsFile)
        var text: String?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text else { return "(Couldn't read \(Self.quickFactsFile).)" }
        return Self.withoutFrontmatter(text)
    }

    // Local Jarvis's personal facts (15/11/2026). Its first live test
    // invented hobbies for Carl: the only note it read, Mobile Quick
    // Facts, holds project status and nothing personal. This is the real
    // source: the bullet lines of About Carl, and only those (its heading
    // and its notes to whoever maintains it aren't facts about Carl).
    // nil when it can't be read, so the app can say so itself. Capped to
    // fit the on-device model's small context.
    private func readAboutCarl() -> String? {
        guard let folder = vaultFolder() else { return nil }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        let file = Self.aboutCarlPath.reduce(folder) { $0.appendingPathComponent($1) }
        var text: String?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text else { return nil }
        let facts = Self.withoutFrontmatter(text)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
        return facts.isEmpty ? nil : String(facts.prefix(2500))
    }

    // Shared conversation memory across brains (14/11/2026, backlog #40).
    // Same read-side idea lean_brain.py's _vault_context uses on the
    // laptop: headlines only. Two sources since 15/11/2026 (#48): the
    // daily note's "## Index" bullets, which the laptop's brains write,
    // and this iPad's own Mobile Jarvis note for the day (see
    // appendConversationDigest for why they're separate files).
    //
    // Today's only, a handful of each, each cut short (15/11/2026):
    // today's and yesterday's full Index ran to about 5,700 characters on
    // every request, eating into Groq's 8,000-tokens-a-minute cap.
    private func readRecentConversations() -> String? {
        guard let folder = vaultFolder() else { return nil }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        let now = Date()
        let index = Self.readDailyNote(folder: folder, date: now)
            .flatMap { Self.indexBullets(from: $0) } ?? ""
        let laptop = index.split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }.suffix(6)
        let mine = Self.readMobileLog(folder: folder, date: now).suffix(4)
        let short = (Array(laptop) + Array(mine)).map { $0.count > 180 ? String($0.prefix(180)) + "…" : $0 }
        return short.isEmpty ? nil : "Today:\n" + short.joined(separator: "\n")
    }

    private static func dailyNotePath(date: Date) -> (month: String, day: String) {
        let month = DateFormatter(); month.dateFormat = "MM - MMMM yyyy"
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        return (month.string(from: date), day.string(from: date) + ".md")
    }

    private static func readDailyNote(folder: URL, date: Date) -> String? {
        let (month, day) = dailyNotePath(date: date)
        let file = folder.appendingPathComponent("01 - Daily Notes")
            .appendingPathComponent(month).appendingPathComponent(day)
        var text: String?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return text
    }

    // The "## Index" section only, up to the next "##" heading — the
    // same headlines-only slice lean_brain.py's _vault_context reads.
    private static func indexBullets(from text: String) -> String? {
        guard let headingRange = text.range(of: "## Index") else { return nil }
        let afterHeading = headingRange.upperBound
        let rest = text[afterHeading...]
        let end = rest.range(of: "\n##").map { $0.lowerBound } ?? rest.endIndex
        let body = rest[rest.index(after: afterHeading)..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // The iPad's own headline note for a day, beside that day's daily
    // note: "2026-11-15 Mobile Jarvis.md" (15/11/2026, #48).
    private static func mobileLogURL(folder: URL, date: Date) -> URL {
        let (month, day) = dailyNotePath(date: date)
        let name = day.replacingOccurrences(of: ".md", with: " Mobile Jarvis.md")
        return folder.appendingPathComponent("01 - Daily Notes")
            .appendingPathComponent(month).appendingPathComponent(name)
    }

    private static func mobileLogHeader(date: Date) -> String {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let long = DateFormatter(); long.dateFormat = "EEEE, d MMMM yyyy"
        return """
        ---
        status: active
        project: jarvis
        type: log
        created: \(day.string(from: date))
        ---
        # Mobile Jarvis — \(long.string(from: date))

        One line per exchange with Jarvis on the iPad, oldest first. Only the iPad app writes to this \
        note; everything else just reads it. The day's main note is [[\(day.string(from: date))]].


        """
    }

    // The day's headline lines from the iPad's own note; empty if there
    // isn't one yet.
    private static func readMobileLog(folder: URL, date: Date) -> [String] {
        let file = mobileLogURL(folder: folder, date: date)
        var text: String?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return (text ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
    }

    // The write side: one short, mechanical line (not an LLM summary —
    // cost/reliability risk) per exchange (14/11/2026, #40). Since
    // 15/11/2026 (#48) it goes in the iPad's OWN note for the day, never
    // the shared daily note. It used to insert its line into the daily
    // note by rewriting the whole file from this iPad's copy, and when
    // that copy was behind the laptop's it wiped every laptop entry
    // written since (twice on 15/11/2026). With one writer per file that
    // can't happen: this iPad's copy of its own note is always the newest.
    private func appendConversationDigest(question: String, answer: String) {
        guard let folder = vaultFolder() else { return }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        let now = Date()
        let file = Self.mobileLogURL(folder: folder, date: now)
        let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "h:mm a"
        let q = String(question.prefix(100))
        let a = String(answer.replacingOccurrences(of: "\n", with: " ").prefix(160))
        let label = brain == .local ? "Mobile Jarvis (iPad), Local Model" : "Mobile Jarvis (iPad), Cloud Model"
        let bullet = "- **\(label)** (\(timeFormatter.string(from: now))): " +
            "asked \"\(q)\" — answered \"\(a)\"\n"
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordError) { url in
            let fm = FileManager.default
            var text: String
            if fm.fileExists(atPath: url.path) {
                // There but unreadable: leave it alone rather than replace it.
                guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
                text = existing
            } else {
                try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                text = Self.mobileLogHeader(date: now)
            }
            if !text.hasSuffix("\n") { text += "\n" }
            text += bullet
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func withoutFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let parts = text.components(separatedBy: "\n---")
        guard parts.count > 1 else { return text }
        return parts.dropFirst().joined(separator: "\n---").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Speaking

    private func say(_ text: String, thenListen: Bool) {
        chatLines.append(ChatLine(who: .jarvis, text: text))
        listenAfterSpeaking = thenListen
        setMode(.speaking)
        guard CloudVoiceKey.isSet else {
            sayWithDeviceVoice(text)
            return
        }
        Task {
            if let data = await CloudVoice.fetchAudio(text: text),
               let player = try? AVAudioPlayer(data: data) {
                self.playCloudVoice(player)
            } else {
                // Degrade, never mute — same rule as the laptop's own
                // voice line on any ElevenLabs failure.
                self.sayWithDeviceVoice(text)
            }
        }
    }

    private func sayWithDeviceVoice(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.britishVoice()
        u.volume = effectiveVolume
        synth.speak(u)
    }

    private func playCloudVoice(_ player: AVAudioPlayer) {
        audioPlayer = player
        player.delegate = self
        player.volume = effectiveVolume
        player.play()
        // AVAudioPlayer gives no per-word boundary like AVSpeechSynthesizer
        // does, so the Radial's word-pulse is approximated on a fixed
        // cadence while it plays — timing is made up, same honest
        // limitation already documented for the Radial's waveform.
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.wordSpoken() }
        }
    }

    // A British voice, the best quality installed (Settings → Accessibility →
    // Spoken Content → Voices can add a better one).
    private static func britishVoice() -> AVSpeechSynthesisVoice? {
        let british = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        let best = british.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            return a.name != "Daniel" && b.name == "Daniel"
        }
        return best ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    fileprivate func wordSpoken() {
        lastWordAt = Date()
        onWord?()
    }

    fileprivate func doneSpeaking() {
        guard mode == .speaking else { return }
        if listenAfterSpeaking && lastTurnByVoice {
            startListening()
            armSleepTimer()
        } else {
            goToSleep()
        }
    }
}

extension JarvisEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in self.wordSpoken() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.doneSpeaking() }
    }
}

extension JarvisEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.pulseTimer?.invalidate()
            self.pulseTimer = nil
            self.doneSpeaking()
        }
    }
}

// MARK: - Weather and websites, handled by the app (16/11/2026)
//
// Carl: "show me the weather at Atherton tomorrow", "show me the weather
// tomorrow at home", "open the BOM website", "open the Bunnings website".
// Both models get the same, predictable result: the app finds the REAL
// page with a web search (never an address from a model's memory, the
// open_webpage rule since 14/11/2026) and shows it in the display pane.
// The Cloud Model used to pick Wikipedia for "the Bunnings website".
extension JarvisEngine {
    /// "Home", or no place at all, means here. About Carl: "For the weather
    /// at home, he uses the Bureau of Meteorology (BOM) forecast for
    /// Silver Valley."
    static let homePlace = "Silver Valley"

    /// Words the speech recogniser should expect (see startListening).
    static let speechHints = ["BOM", "Bureau of Meteorology", "BOM website", "BOM weather",
                              "Silver Valley", "Atherton", "Ravenshoe", "Herberton", "Mareeba",
                              "Malanda", "Yungaburra", "Tolga", "Cairns", "Bunnings"]

    /// The recogniser hears "BOM" as "bomb". In a sentence about weather,
    /// or right before "website", it can only mean the Bureau.
    static func fixMishearings(_ text: String) -> String {
        var fixed = text
        // Spelled out: "B O M", "b.o.m."
        fixed = fixed.replacingOccurrences(of: #"(?i)\bb\.?\s?o\.?\s?m\.?(?=\s|$|[?!,])"#,
                                           with: "BOM", options: .regularExpression)
        // "the bomb website", "bomb weather", "bombs site"
        fixed = fixed.replacingOccurrences(
            of: #"(?i)\bbombs?\b(?=('s)?\s+(website|web site|site|page|web page|weather|forecast|radar|app)\b)"#,
            with: "BOM", options: .regularExpression)
        // Any "bomb" in a sentence about the weather
        if fixed.range(of: #"(?i)\b(weather|forecast|radar|rain)\b"#, options: .regularExpression) != nil {
            fixed = fixed.replacingOccurrences(of: #"(?i)\bbombs?\b"#, with: "BOM", options: .regularExpression)
        }
        return fixed
    }

    /// The place to show the weather for, or nil if this isn't a request to
    /// see the weather. "Home" and no place at all both mean homePlace.
    static func weatherPlace(in text: String) -> String? {
        let t = text.lowercased()
        guard t.range(of: #"\b(weather|forecast|bom|bureau of meteorology)\b"#,
                      options: .regularExpression) != nil,
              t.range(of: #"\b(show|open|bring up|pull up|display|let me see|look at|check|what'?s|what is|how'?s|how is|give me|get me|go to|load|see)\b"#,
                      options: .regularExpression) != nil else { return nil }
        let pattern = #"\b(?:at|in|for|around|near)\s+([a-z][a-z' -]*?)(?=\s+(?:today|tomorrow|tonight|this|next|on|over|for|at|in|please|weather|forecast)\b|[?.!,]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return homePlace }
        let ns = t as NSString
        for match in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            var place = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if place.hasPrefix("the ") { place.removeFirst(4) }
            if place.isEmpty || isTimeOrSourceWord(place) { continue }
            if ["home", "my place", "my house", "our place", "our house", "house"].contains(place) {
                return homePlace
            }
            return place.capitalized
        }
        return homePlace
    }

    /// "for tomorrow", "for the weekend", "on the BOM website": not places.
    private static func isTimeOrSourceWord(_ s: String) -> Bool {
        let words: Set<String> = ["today", "tomorrow", "tonight", "morning", "afternoon", "evening",
                                  "week", "weekend", "moment", "now", "bom", "bom website", "website",
                                  "bureau of meteorology", "weather", "forecast", "monday", "tuesday",
                                  "wednesday", "thursday", "friday", "saturday", "sunday"]
        return words.contains(s) || s.hasPrefix("next ") || s.hasPrefix("this ")
            || s.hasPrefix("bom ") || s.hasSuffix(" days")
    }

    /// "today", "tomorrow" or a weekday the question mentions, if any.
    private static func dayAsked(in text: String) -> String? {
        let t = text.lowercased()
        for day in ["tomorrow", "tonight", "today", "monday", "tuesday", "wednesday", "thursday",
                    "friday", "saturday", "sunday", "weekend"] where t.contains(day) {
            return day
        }
        return nil
    }

    /// Finds the real BOM forecast page for `place` and shows it.
    func showWeather(at place: String, question: String) async {
        searching = true
        let page = await Self.bomPage(for: place)
        searching = false
        // Carl may have tapped the orb to stop while it was searching.
        guard mode == .thinking else { return }
        guard let page else {
            answer = "I couldn't find a Bureau of Meteorology forecast page for \(place), sir."
            say(answer, thenListen: true)
            return
        }
        show(page)
        var line = "Here's the Bureau of Meteorology forecast for \(place), sir."
        let day = Self.dayAsked(in: question) ?? ""
        switch day {
        case "tomorrow": line += " Tomorrow's is the second day."
        case "weekend": line += " The weekend's further along."
        case "", "today", "tonight": break
        default: line += " Look for \(day.capitalized)."
        }
        answer = line
        say(line, thenListen: true)
    }

    /// The BOM forecast page for a Queensland place. Every BOM town page
    /// has the same shape (bom.gov.au/places/qld/silver-valley/forecast,
    /// checked 16/11/2026), so the address is built, then confirmed: it
    /// must open and its title must name the place ("Silver Valley Forecast
    /// - Bureau of Meteorology"). A search limited to bom.gov.au is the
    /// fallback (it missed Silver Valley entirely in testing). Remembered
    /// once confirmed, so asking again is instant. Never a "nearest" page:
    /// no match means saying so.
    private static func bomPage(for place: String) async -> URL? {
        let memoryKey = "Jarvis.BOMPage." + place.lowercased()
        if let saved = UserDefaults.standard.string(forKey: memoryKey), let url = URL(string: saved) {
            return url
        }
        let name = place.lowercased()
        let slug = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        var candidates: [URL] = []
        if let built = URL(string: "https://www.bom.gov.au/places/qld/\(slug)/forecast") {
            candidates.append(built)
        }
        for result in await tavily(query: "\(place) Queensland forecast", domains: ["bom.gov.au"]) {
            let path = result.url.path.lowercased()
            if path.contains("/places/"), path.contains("/\(slug)/"), !candidates.contains(result.url) {
                candidates.append(result.url)
            }
        }
        for url in candidates {
            if let title = await pageTitle(of: url), title.lowercased().contains(name) {
                UserDefaults.standard.set(url.absoluteString, forKey: memoryKey)
                return url
            }
        }
        return nil
    }

    /// The website name in "open the Bunnings website", "show me the ABC
    /// News site", or nil if this isn't a request to open a website.
    static func websiteName(in text: String) -> String? {
        let t = text.lowercased()
        let pattern = #"\b(?:open|show me|bring up|pull up|go to|take me to|load|launch)\s+(?:up\s+)?(?:the\s+|my\s+)?(.+?)\s+(?:website|web site|site|web page|webpage|home ?page)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) else {
            return nil
        }
        let name = (t as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Opens a site's own home page, never Wikipedia, a company directory
    /// or social media. In testing (16/11/2026) a search for "Bunnings
    /// official website" returned only directory sites, so: first a search
    /// result whose address carries the name (exact name and .au first); failing that, name.com.au
    /// then name.com, used only if the page's own title carries the name
    /// (abcnews.com.au answers, but isn't the ABC).
    func showWebsite(named name: String) async {
        searching = true
        let home = await Self.officialSite(for: name)
        searching = false
        guard mode == .thinking else { return }
        let spokenName = Self.spoken(name)
        guard let home else {
            answer = "I couldn't find the \(spokenName) website, sir."
            say(answer, thenListen: true)
            return
        }
        show(home)
        answer = "Here's the \(spokenName) website, sir."
        say(answer, thenListen: true)
    }

    private static func officialSite(for name: String) async -> URL? {
        let filler: Set<String> = ["the", "and", "news", "shop", "store", "online", "australia", "official", "my"]
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        let keys = words.filter { !filler.contains($0) }.isEmpty ? words : words.filter { !filler.contains($0) }
        guard !keys.isEmpty else { return nil }
        let notOfficial = ["wikipedia.org", "facebook.com", "instagram.com", "linkedin.com", "youtube.com",
                           "twitter.com", "x.com", "reddit.com", "tiktok.com", "pinterest.com", "yelp.com",
                           "tripadvisor.com", "tripadvisor.com.au", "glassdoor.com", "indeed.com", "seek.com.au",
                           "productreview.com.au", "leadiq.com", "rocketreach.co", "tavily.com", "crunchbase.com",
                           "zoominfo.com", "dnb.com", "bloomberg.com", "cbinsights.com", "craft.co"]
        func carriesName(_ host: String) -> Bool { keys.contains { host.contains($0) } }
        let joined = keys.joined()
        // "www.officeworks.com.au" -> "officeworks"
        func mainLabel(_ host: String) -> String {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return bare.components(separatedBy: ".").first ?? bare
        }
        var matches: [String] = []
        for result in await tavily(query: "\(name) official website Australia", domains: nil) {
            guard let host = result.url.host()?.lowercased(),
                  !notOfficial.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  carriesName(host), !matches.contains(host) else { continue }
            matches.append(host)
        }
        // Exactly the name beats merely containing it (officeworks.com.au, not
        // officeworksphotos.com.au); Australian beats foreign (abc.net.au, not
        // the American abcnews.com). Both seen in testing, 16/11/2026.
        let exactAustralian = matches.first(where: { mainLabel($0) == joined && $0.hasSuffix(".au") })
        let exact = matches.first(where: { mainLabel($0) == joined })
        let australian = matches.first(where: { $0.hasSuffix(".au") })
        let best = exactAustralian ?? exact ?? australian ?? matches.first
        if let best, let url = URL(string: "https://\(best)/") { return url }
        for guess in ["https://www.\(joined).com.au/", "https://www.\(joined).com/"] {
            guard let url = URL(string: guess), let title = await pageTitle(of: url) else { continue }
            if keys.contains(where: { title.lowercased().contains($0) }) { return url }
        }
        return nil
    }

    /// "abc news" -> "ABC News", "bunnings" -> "Bunnings": short names read as letters.
    private static func spoken(_ name: String) -> String {
        name.split(separator: " ").map { word in
            word.count <= 3 ? word.uppercased() : word.capitalized
        }.joined(separator: " ")
    }

    /// A page's <title>, or nil if it doesn't open (anything but HTTP 200).
    /// Sent with a Safari user agent: some sites, BOM among them, turn
    /// away requests that don't look like a browser.
    private static func pageTitle(of url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let html = String(decoding: data.prefix(200_000), as: UTF8.self)
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let open = html.range(of: ">", range: start.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive,
                                     range: open.upperBound..<html.endIndex) else { return "" }
        return String(html[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts a page in the display pane, replacing any pictures.
    private func show(_ url: URL) {
        openWebPage = url
        generatedImage = nil
        foundPhotos = []
    }

    /// A Tavily search returning real result addresses and titles,
    /// optionally limited to some sites. Same key and plan as WebSearch.
    private static func tavily(query: String, domains: [String]?) async -> [(url: URL, title: String)] {
        guard let key = SearchKey.load() else { return [] }
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["query": query, "search_depth": "basic", "max_results": 5]
        if let domains { body["include_domains"] = domains }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = bodyData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result -> (url: URL, title: String)? in
            guard let urlString = result["url"] as? String, let url = URL(string: urlString) else { return nil }
            return (url, result["title"] as? String ?? "")
        }
    }
}
