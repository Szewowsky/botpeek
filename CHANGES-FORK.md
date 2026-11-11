# About this fork

A personal build of [BotPeek](https://github.com/deni0107/botpeek) (MIT, see
`LICENSE` and `THIRD_PARTY_NOTICES.md`, both unchanged). Based on upstream 0.1.1.

## Differences from upstream

- **Polish Grok Bot interface.** Upstream matches only Grok Bot's English
  Accessibility labels, so on a Polish Mac it couldn't find the sidebar ("Boty")
  and every reply failed with "Grok Bot's window isn't available". All Grok Bot
  labels now live in `Sources/BotPeekCore/Grok/GrokBotLabels.swift`, each with its
  English and Polish variants; the parsers accept either. English works as before.
  Polish strings and their sources: `docs/LOCALIZATION.md`.
- **Polish sign-offs** ("Coś jeszcze?", "Czy mogę jeszcze w czymś pomóc?") don't count
  as questions waiting for an answer.
- **Sidebar folders.** Grok Bot 0.79 files bots in folders, and a collapsed folder's
  bots have no button, so upstream failed with "bot not found". BotPeek now reads
  the folders from Grok Bot's cache (`SidebarSectionStore`), opens the one folder
  holding the bot (`SidebarFolderMatcher`, strict: anything unclear means nothing is
  pressed), and closes it again when the operation ends
  (`GrokAccessibilityDriver.restoringSidebar`). Folders the user opened stay open.
- **Compact sidebar.** In a narrow window Grok Bot shows a compact sidebar without
  folder buttons. When a bot's folder isn't shown and the sidebar is compact
  (`SidebarMode`), BotPeek switches it to full with the "Toggle compact sidebar"
  button, opens the folder, and afterwards closes the folder and makes the sidebar
  compact again. A sidebar the user made full stays full. In a narrow background
  window Grok Bot applied the switch back to compact only some 15-30 s later.
- **Safer replies.** The send button is looked for outward from the "Prompt" box
  (its parent, then each wider ancestor, never the window itself), never in the
  transcript, and exactly one must match at the nearest level that has any;
  otherwise nothing is pressed, so a bot's own "Send"/"Wyślij" option is never
  taken for it. Requests that must be answered in Grok Bot (cached approvals,
  forms) are never read from the window, a window reading never lifts that lock or
  turns an approval into a plain choice, and `ReplyCoordinator` rejects any reply
  to them. Polish approve and deny words ("Zatwierdź", "Odrzuć", …) count as an
  approval; the list is in `docs/LOCALIZATION.md`.
- **Tests:** `PolishInterfaceTests`, `testPolishPlainQuestionHeuristics`,
  `SidebarFolderTests`, `SendButtonTests`,
  `testGrokBotOnlyRequestsKeepTheirLockAfterAWindowReading` and
  `testGrokBotOnlyRequestsRejectEveryReply`.
- **Bundle identifier** `io.github.szewowsky.botpeek` (upstream:
  `io.github.deni0107.botpeek`), so this build has its own Accessibility permission
  and settings and doesn't collide with an installed upstream copy.

## Building with a signature

```bash
swift test
ARCHS=arm64 DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
dist/BotPeek.app/Contents/MacOS/BotPeek --version
dist/BotPeek.app/Contents/MacOS/BotPeek --check
```

A stable signature keeps the Accessibility permission across rebuilds; ad-hoc builds
(no `DEVELOPER_ID_APPLICATION`) need it granted again each time. Run only
`--version`, `--check`, `--probe-open` or `--render-avatars` from the terminal: any
other argument starts the full app.

## Pulling upstream changes

```bash
git fetch upstream
git switch polskie-etykiety
git merge upstream/main        # or: git rebase upstream/main
swift test
```

Conflicts are most likely in `AXNodeSnapshot.swift` (`SidebarParser`),
`TranscriptParser.swift`, `ConversationRequestParser.swift` (`PlainQuestion`),
`Tests/BotPeekCoreTests/TestSupport.swift` and `Resources/Info.plist`. If upstream adds
a new English label, add its Polish twin to `GrokBotLabels` (see the re-check steps
in `docs/LOCALIZATION.md`).
