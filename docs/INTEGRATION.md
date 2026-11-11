# How BotPeek talks to Grok Bot

Grok Bot has no public API for third-party apps, so BotPeek combines two local
techniques: it reads Grok Bot's cache files (read-only) and drives its window through
Accessibility. Everything here was checked against Grok Bot 0.78.1 and may change with
any Grok Bot update.

## Local data (read-only)

Location: `~/Library/Application Support/Grok Bot/`. BotPeek never writes here and
never reads credentials.

- **Roster:** in `sand-client-persistence/*.blob`, a key-value cache whose file names are
  base32 (RFC 4648, lowercase, no padding) encodings of their keys. The roster is the
  newest file whose key ends in `.roster.last-roster`:

  ```json
  { "schemaVersion": 4,
    "value": { "rows": [
      { "id": "…", "name": "Research Bot",
        "avatarShape": "cloud", "avatarColor": "blue",
        "avatarPhoto": { "kind": "file", "key": "<32 hex chars>" },
        "awaitingUserResponse": { … } | null,
        "hasUnread": false, "lastActivityAt": 1730000000000 } ] } }
  ```

- **Conversations:** the file whose key is `<account>.transcript.replicas.<bot id>`.
  BotPeek only checks whether its latest entry is a request still waiting for you:

  ```json
  { "kind": "send-message", "message": { "type": "widget", "widget": {
      "prompt": "…", "options": [ { "label": "…", "value": "…" } ],
      "allowCustom": true, "multiSelect": false } } }
  ```

  A question is answered once it gets `respondedValue`, `widgetSkipped` or
  `widgetDismissed`, or once the conversation moves on. `auto-review-approval` entries
  are open while their `status` is pending, and `user-form` entries until they get a
  `formResolution`; both are answered in Grok Bot only.

  A plain `text` message counts as a question when it's the latest turn, ends in "?",
  isn't a sign-off ("Anything else?"), and the bot has been quiet for 8 seconds.

- **Uploaded avatars:** `roster-avatars/<key>`. Keys must be 32 hex characters.
- **Status:** `desktop-status.json` (`pid`, `signedIn`, `appVersion`), trusted only while
  that process is alive.

Grok Bot 0.78.1 doesn't set `awaitingUserResponse` for questions asked in chat, so the
conversation cache is the main signal.

## Built-in avatars

Grok Bot draws its built-in avatars in JavaScript. At launch BotPeek checks Grok Bot's
code signature, reads the renderer module from `app.asar` in memory, adapts it into a
classic script and runs it in a sandboxed JavaScriptCore context. If anything fails, it
falls back to its own drawings. `BotPeek --render-avatars <folder>` writes every avatar as PNGs.

## Accessibility

Grok Bot (`com.anysphere.sand`) is an Electron app, so BotPeek sets
`AXManualAccessibility` once per process to expose its content. Landmarks, adapted from
[grok-bot-mcp](https://github.com/rthomas24/grok-bot-mcp):

- **Sidebar:** the element labelled `Bots`; each bot is a button labelled `<name>` or `<name>, <status>`.
  Bots can be filed in folders. A collapsed folder is a button labelled
  `<folder> <count>` and its bots have no buttons at all; an open folder's button reads
  `<folder>` (`AXExpanded` doesn't tell folders from bots). The folders and their bots
  come from the cache `<account>.sidebar.last-sections`
  (`{ "value": { "sections": [ { "id", "name", "agentIds": […] } ] } }`). When a bot
  has no button, BotPeek opens its folder, presses the bot, and closes the folder
  again once the reply (or failure) is done; folders the user opened stay open.
  It presses a folder only when the bot is filed in exactly one folder, exactly one
  sidebar button is that folder's, and the folder's name isn't a bot's name or the
  hidden-bots section's.
- **Compact sidebar:** in narrow windows the sidebar is compact: pinned bots and open
  folders' bots only, with no folder buttons and no `Search` button. The
  `Toggle compact sidebar` button switches modes; its `AXExpanded` is true when the
  sidebar is full. BotPeek trusts the mode only when that and the search button agree
  (`SidebarMode`). If a bot's folder isn't shown and the sidebar is compact, BotPeek
  switches it to full (about 0.3 s in the background), then opens the folder; afterwards
  it closes the folder and then makes the sidebar compact again. In a narrow background
  window Grok Bot (0.79.4) applied the switch back to compact only 15-30 s later.
- **Labels by language:** `GrokBotLabels` (English and Polish); see
  [LOCALIZATION.md](LOCALIZATION.md).
- **Conversation:** the first heading is the bot's name; messages sit in
  `Conversation transcript`, each titled `<sender> <time>` (`You` for the user).
- **Questions:** choice buttons inside a group described with the question, often next to a
  `Custom answer` text area. Only the newest message is read.
- **Composer:** the text area described as `Prompt`, sent with `Send message`.

In the background, Grok Bot 0.78.1 applies an Accessibility press only when the next
action arrives, so BotPeek follows each press with a harmless `AXScrollToVisible` and keeps
nudging until the reply shows up in the conversation.

Typed replies are sent in the background by setting the composer's text. Settings →
Connection → Reply delivery can switch to pasting, which briefly brings Grok Bot forward
and then restores the clipboard and the previous app.

## Safety rules

- Bots are matched by exact name only. Duplicate names or no match: nothing is sent.
- The open conversation's heading must match the bot before anything is sent.
- BotPeek never creates bots or conversations, and never overwrites a draft.
- No silent retries: if delivery can't be confirmed, BotPeek says so.
- *Delivered* appears only after the reply shows up in the conversation.

## When Grok Bot changes

Grok Bot-specific strings live in `GrokBotApp`, `RosterParser`, `SidebarParser` and
`TranscriptParser`. Changes show up as warnings in Settings → Connection, in `--check`
output, or as "Couldn't find…" errors that fall back to opening Grok Bot.
