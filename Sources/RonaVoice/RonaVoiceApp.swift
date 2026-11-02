import SwiftUI

@main
struct RonaVoiceApp: App {
    @State private var conversation = Conversation()
    var body: some Scene {
        Window("Rona Voice", id: "conversation") {
            ConversationView(conversation: conversation)
                .task {
                    #if DEBUG
                    if CommandLine.arguments.contains("--smoke-test") {
                        await DevelopmentSmokeTest.run(conversation)
                    }
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 760)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation", action: conversation.clear).keyboardShortcut("n")
                    .disabled(conversation.phase == .preparing)
            }
            CommandGroup(after: .appInfo) {
                Button("Third-Party Notices") {
                    if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}
