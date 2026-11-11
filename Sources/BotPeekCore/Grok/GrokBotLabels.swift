import Foundation

/// Text that Grok Bot shows in its window and that BotPeek matches through
/// Accessibility, in every interface language BotPeek knows.
///
/// Grok Bot follows the system language, so each landmark is a set of accepted
/// variants: English first, then Polish. The Polish strings come from Grok Bot
/// 0.79.4's own translation catalogs (see docs/LOCALIZATION.md). To support
/// another language, add its strings here and a test with them.
public enum GrokBotLabels {
    /// The sidebar that lists the bots.
    public static let sidebar: Set<String> = ["Bots", "Boty"]

    /// The sidebar section of hidden bots. Its button reads "<label> <count>" like
    /// a collapsed folder's, so a folder with this name is never pressed.
    static let hiddenBotsSection: Set<String> = ["Hidden Bots", "Ukryte Boty"]

    /// The button that switches the sidebar between full and compact. A compact
    /// sidebar shows only pinned bots and open folders, without folder buttons.
    static let compactSidebarToggle: Set<String> = ["Toggle compact sidebar", "Przełącz kompaktowy pasek boczny"]

    /// The search button, shown only in the full sidebar.
    static let searchButton: Set<String> = ["Search", "Szukaj"]

    /// Buttons inside the sidebar list that are not bots.
    static let nonBotButtons: Set<String> = [
        "Toggle compact sidebar", "Search", "New chat", "Connect apps",
        "Przełącz kompaktowy pasek boczny", "Szukaj", "Nowy czat", "Połącz aplikacje",
    ]

    /// Lowercased phrases in a sidebar status that mean the bot waits for the user.
    static let attentionPhrases = [
        "waiting for you", "needs you", "needs your", "awaiting your", "approval required",
        "answer needed", "has a question", "needs approval",
        "czeka na ciebie", "wymaga twojego", "wymaga twojej", "potrzebuje twojej",
        "wymagane zatwierdzenie", "wymaga zatwierdzenia",
    ]

    /// The container that holds the conversation's messages.
    public static let transcript: Set<String> = ["Conversation transcript", "Zapis rozmowy"]

    /// The sender of the user's own messages.
    public static let userSenders: Set<String> = ["You", "Ty"]

    static let dismissQuestion: Set<String> = ["Dismiss question", "Ukryj pytanie"]
    static let customAnswer: Set<String> = ["Custom answer", "Własna odpowiedź"]
    static let messageActionsPrefixes = ["Message actions", "Akcje wiadomości"]

    /// The message box. Grok Bot doesn't translate it.
    public static let composer: Set<String> = ["Prompt"]

    /// "Prześlij" (Polish "Submit") is left out on purpose: Grok Bot also uses
    /// it for "Upload".
    static let sendButtons: Set<String> = ["Send", "Send message", "Submit", "Wyślij", "Wyślij wiadomość"]

    static func hasMessageActionsPrefix(_ label: String) -> Bool {
        messageActionsPrefixes.contains { label.hasPrefix($0) }
    }
}
