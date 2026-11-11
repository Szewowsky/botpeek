# Grok Bot interface languages

Grok Bot follows the macOS system language, so the Accessibility labels BotPeek
matches change with it. All accepted variants live in one place:
`Sources/BotPeekCore/Grok/GrokBotLabels.swift`. Supported today: English and Polish.

## Where the translations come from

Grok Bot 0.79.4 ships its interface strings as Lingui catalogs inside
`/Applications/Grok Bot.app/Contents/Resources/app.asar`, as
`JSON.parse(...)` blocks in the renderer bundles under `dist/renderer/assets/`.
Each message has a short hashed id (for example `j/JxNY`) that is the same in every
language, so a Polish string is found by looking up the id of the English one.

- English: `index.eager-app-CYjmNGFy.js` (catalog #0 "agents", #1 "chat") and
  `index.eager-common-C5GMt_wm.js` (#0 "core", #1 "shared").
- Polish: `chunk-agents-BpJ2j0x3.js`, `chunk-chat-DszGMPu3.js`,
  `chunk-core-BUjmiLIm.js`, `chunk-shared-CRqJDDpw.js`.

The file names carry content hashes and change with every Grok Bot release; the
message ids normally don't. `dist/electron-main/locales/pl/messages.cjs` holds only
the main process (menus, dialogs), not the window content.

"Live" means the label was seen in Grok Bot's Accessibility tree on a Polish Mac
(Grok Bot 0.79.4, November 2026).

## Labels BotPeek matches

| English | Polish | Source (Polish file : id) | Seen live |
|---|---|---|---|
| Bots (sidebar) | Boty | chunk-agents-BpJ2j0x3.js : `BIDT9R` | yes |
| Toggle compact sidebar (also switches the sidebar to full and back; `AXExpanded` true = full) | Przełącz kompaktowy pasek boczny | chunk-agents-BpJ2j0x3.js : `+OFRL2` | yes, in both modes |
| Search (only in the full sidebar; tells full from compact) | Szukaj | chunk-agents-BpJ2j0x3.js : `A1taO8` | yes, full sidebar only |
| New chat | Nowy czat | chunk-core-BUjmiLIm.js : `hIQkLb` | no |
| Connect apps | Połącz aplikacje | chunk-agents-BpJ2j0x3.js : `h8AWBN` | yes |
| Conversation transcript | Zapis rozmowy | chunk-chat-DszGMPu3.js : `j/JxNY` | yes |
| You (message sender) | Ty | chunk-chat-DszGMPu3.js : `kWJmRL` (also `t0zWb2` in agents) | yes |
| Prompt (message box) | Prompt (not translated) | chunk-chat-DszGMPu3.js : `W9uQXX` | yes |
| Dismiss question | Ukryj pytanie | chunk-chat-DszGMPu3.js : `i+D6RG` | no |
| Custom answer | Własna odpowiedź | chunk-chat-DszGMPu3.js : `dN9Fia` | no |
| Message actions (prefix) | Akcje wiadomości | chunk-chat-DszGMPu3.js : `+nYs0G`, `lKwbtc` ("Akcje wiadomości od {owner} z {0}") | no |
| Send message | Wyślij wiadomość | chunk-chat-DszGMPu3.js : `pi1oME` | no |
| Send | Wyślij | chunk-chat-DszGMPu3.js : `JlFcis` | no |
| Submit | Prześlij - **not used**, see below | chunk-chat-DszGMPu3.js : `hQRttt` | no |
| Hidden Bots (sidebar section; a folder with this name is never pressed) | Ukryte Boty | chunk-agents-BpJ2j0x3.js : `JuesWZ` | yes (group and button "Ukryte Boty <count>") |

Folder names in the sidebar are the user's own and aren't translated. A collapsed
folder's button reads `<folder> <count>`, an open one `<folder>`; the folders and
their bots come from Grok Bot's cache `<account>.sidebar.last-sections` (see
`docs/INTEGRATION.md`).

Message titles keep the form `<sender> HH:MM:SS` (24-hour clock on a Polish Mac),
which the existing time pattern already accepts. Seen live: `Ty HH:MM:SS`.

Other Polish labels seen live, for orientation (BotPeek doesn't match them):
`Lista Botów` (`nhxF89`), `Przypięte Boty` (`vPVg0Q`),
`Zmień rozmiar paska bocznego` (`cyFaZJ`), `Udostępnij` (`Z8lGw6`),
`Główny Bot` (`V8a0q9`), `Nowy Bot` (`2hjDEV`, English "New Bot").

### Sidebar status phrases (fallback signal)

BotPeek reads a status after the bot name in a sidebar button only when the caches
have nothing. The English phrases are substrings, so the Polish ones are too:

| English phrase | Polish phrase | Polish catalog strings it comes from |
|---|---|---|
| waiting for you | czeka na ciebie | `fZI5Tx` "Czeka na Ciebie: …", `w3griw` "Czeka na Ciebie", `0lMXxL` "{0} — czeka na Ciebie" |
| needs your | wymaga twojego, wymaga twojej | `f8c8eA` "Wymaga Twojego zatwierdzenia", `HB0Zic`, `HzHovd` |
| needs your (input) | potrzebuje twojej | `1OU+O9` "Potrzebuje Twojej odpowiedzi" |
| approval required | wymagane zatwierdzenie | `4wavf2` "Wymagane zatwierdzenie: …" |
| needs approval | wymaga zatwierdzenia | `hXCTWg` "Wymaga zatwierdzenia" |
| needs you | (covered by "czeka na ciebie") | `0lMXxL` |
| awaiting your | - not found in the catalogs | - |
| answer needed | - not found in the catalogs | - |
| has a question | - not found in the catalogs | - |

None of these status texts were seen live in a sidebar button.

### Plain-text sign-offs

Questions asked in an ordinary message are read from the cache, so their language is
the bot's, not Grok Bot's interface. Polish sign-offs that don't count as a question:
`coś jeszcze`, `jeszcze coś`, `czegoś jeszcze`, `jeszcze czegoś`, `w czymś jeszcze`,
`jeszcze w czymś`, `w czym jeszcze`, `jakieś pytania`, `jakieś inne pytania`
(for example "Coś jeszcze?", "Czy mogę jeszcze w czymś pomóc?", "Masz jakieś pytania?").
These are BotPeek's own list, not Grok Bot strings.

### Approve and deny words

Options that start with these words (any letter case) make a question an approval,
which BotPeek handles only with "Approve or deny inline" on and a second click.
Bots name their options themselves, so these are BotPeek's own list
(`GrokBotLabels.approveWords` / `denyWords`), not Grok Bot strings:

| Kind | English | Polish |
|---|---|---|
| Approve | approve, allow, accept, confirm, "yes, run", run it, proceed, continue | zatwierdź, zezwól, akceptuj, potwierdź, kontynuuj, uruchom, "tak, uruchom" |
| Deny | deny, reject, decline, don't allow, do not allow, cancel, block | odrzuć, odmów, anuluj, zablokuj, nie zezwalaj |

"Tak" and "Nie" alone stay a plain choice: yes/no without context isn't an approval.

## Deliberate omissions

- **Prześlij.** Polish uses the same word for "Submit" (`hQRttt`) and "Upload"
  (`ONWvwQ`). BotPeek takes the first button whose label is a send label, so accepting
  "Prześlij" could pick an upload button. The composer's own send button is
  "Wyślij wiadomość" (`pi1oME`), which is accepted.
- **Własna odpowiedź** also translates "Your own answer" (`irCsCY`). Both mean a free
  answer box, so this is harmless.

## Re-checking after a Grok Bot update

1. Read the `app.asar` header (a 16-byte pickle prefix, then JSON with each file's
   `offset` and `size`; data starts at `8 + header pickle size`).
2. In `dist/renderer/assets/*.js`, parse every ``JSON.parse(`{...}`)`` block.
3. Find the English catalog containing an English label and take its id, then read
   the same id from the Polish catalog (the one whose strings are Polish).
4. Update `GrokBotLabels.swift`, this table and `PolishInterfaceTests`.
