> [!IMPORTANT]
> **This is a fork** of [deni0107/botpeek](https://github.com/deni0107/botpeek). It adds
> support for Grok Bot's Polish interface, for bots filed in collapsed sidebar folders
> and for the compact sidebar. Details: [CHANGES-FORK.md](CHANGES-FORK.md).
>
> **Po polsku:** to wersja BotPeek, która działa z polskim interfejsem Grok Bota, z botami
> w zwiniętych folderach i z wąskim paskiem bocznym. Pobierz plik DMG z
> [najnowszego wydania](https://github.com/Szewowsky/botpeek/releases/latest), przeciągnij
> BotPeek do Aplikacji i przy pierwszym uruchomieniu zezwól na Dostępność (Accessibility).

<div align="center">

<img src="docs/images/icon.svg" width="112" alt="BotPeek icon">

# BotPeek

**Your Grok Bot bots visit you, not the other way around.**

When a bot needs an answer or an approval, it peeks out from the edge of your Mac's
screen, takes your reply, and hops back out of sight.

[Download](https://github.com/Szewowsky/botpeek/releases/latest) ·
[How it works](docs/INTEGRATION.md)

[![CI](https://github.com/deni0107/botpeek/actions/workflows/ci.yml/badge.svg)](https://github.com/deni0107/botpeek/actions/workflows/ci.yml)
[![MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

<img src="docs/images/demo.gif" width="800" alt="Bots peek from the screen edge while you work, you answer each with one click, and they hop back out of sight">

<img src="docs/images/peek.png" width="270" alt="A violet bot peeking from the right edge of the screen with a preview of its question">
<img src="docs/images/choice.png" width="270" alt="The bot's card open, asking which of three vendors to contact, with an answer button for each">
<img src="docs/images/delivered.png" width="270" alt="The same card after picking Northwind Supply, showing Delivered">
<br><sub>A real Grok Bot question in BotPeek on macOS 26: it peeks, you answer, it's delivered.</sub>

</div>

> [!NOTE]
> Beta, provided as is. Tested with macOS 26 and Grok Bot 0.78.1. BotPeek is an
> independent project, not affiliated with Grok Bot, xAI or Cursor.

## Features

- **Appears only when needed:** questions (with buttons or in plain text), approvals and
  forms. Never for ordinary messages, progress or unread counts.
- **Your real bots,** with their names and avatars from Grok Bot's local data.
- **Answer in place:** pick an option or type a reply without switching to Grok Bot.
  *Delivered* is shown only once the reply is confirmed. Approvals and sign-in forms open
  in Grok Bot unless you opt in to inline approvals.
- **Several bots at once,** newest first, with snooze, dismiss and a menu-bar list.
- **Out of the way:** never steals focus, click-through, works across Spaces and full
  screen, respects Reduce Motion. ⌃⌥B opens the current request from any app.
- **Private:** no network access, no analytics, message text is never saved.

## Install

1. Download the DMG from the [latest release](https://github.com/Szewowsky/botpeek/releases/latest)
   and drag BotPeek into Applications. Requires macOS 14 or newer.
2. If macOS says it can't verify the developer, go to **System Settings → Privacy &
   Security** and click **Open Anyway**.
3. Allow **Accessibility** when asked. It's needed to read questions and send replies;
   without it, characters still appear and open Grok Bot.

No Grok Bot? Turn on **Demo Mode** from the menu bar.

**Known limitations:** assumes Grok Bot's English UI; replying switches Grok Bot's open
conversation in the background; unsigned updates need Accessibility granted again.

## Build from source

Requires macOS 14+ and Xcode 16.

```bash
swift test                # run the tests
swift run BotPeek         # run the app
./scripts/build-app.sh    # build dist/BotPeek.app
./scripts/package.sh      # build the DMG and ZIP
```

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). This is a
spare-time project, so there's no promise of support or fixes.

## License

[MIT](LICENSE). Includes code adapted from grok-bot-mcp; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
