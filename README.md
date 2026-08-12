<p align="center">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIcon.appiconset/icon_512.png" width="160" alt="The Cherry app icon">
</p>

<h1 align="center">Cherry</h1>

<p align="center">
  <b>A web browser for macOS, with a cat in it.</b><br>
  WebKit underneath. A local model that reads the page you are on. An MCP server<br>
  so Claude Code and Codex can drive it. And Pearl, who lives on your pages.
</p>

<p align="center">
  <sub>
    Personal project · macOS 26.2 or later · not on the App Store · no Developer ID
  </sub>
</p>

---

## The thirty-second version

Cherry is a Mac browser built by one person. It renders with `WKWebView`, the same
engine Safari uses, so pages look and behave the way they do in Safari — Cherry is
the browser around that, not a new engine.

What makes it worth a look is the three things wrapped around it:

**Pearl.** A cat. She introduces the browser on first run, and if you switch her on
she stands on the web pages you read — you pick her up and put her where you want,
she sleeps if you ignore her, and there is a fish. When the network drops, she is
also the game on the offline page.

**On-device AI.** A side panel that reads the page you are on and answers questions
about it, running either on Apple's on-device model or on a local Qwen you download
yourself. Nothing about your page leaves the Mac. It can also research across several
open tabs at once with citations, or run a single read-only web search and answer
from what it finds.

**An MCP server.** Switch it on and Cherry serves nine tools on `127.0.0.1` behind a
bearer token. Claude Code or Codex can then list your tabs, read the page you are
looking at, search your history, open a tab — and, only after asking you in a dialog,
click and type in one tab for a limited number of minutes.

Everything on this page is in the code. Where something is partial, half-working or
only true under a condition, the condition is written next to it rather than left out.

---

## Pearl

<p align="center">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/PearlWave.imageset/PearlWave%402x.png" height="150" alt="Pearl waving">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/PearlSitting.imageset/PearlSitting%402x.png" height="150" alt="Pearl sitting">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/PearlDelighted.imageset/PearlDelighted%402x.png" height="150" alt="Pearl delighted">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/PearlCurled.imageset/PearlCurled%402x.png" height="150" alt="Pearl curled up asleep">
</p>

<p align="center">
  <sub>
    Four of her five drawn poses, from <code>Assets.xcassets</code>:
    <code>PearlWave</code>, <code>PearlSitting</code>, <code>PearlDelighted</code>,
    <code>PearlCurled</code>. Her eyes ship purple
    (<code>PearlEyes.shipping</code>); the amber originals are kept in
    <code>Tools/pearl-eyes/amber/</code>.
  </sub>
</p>

She is three separate things that share a name and an art style.

### The first run

The first time you open Cherry she takes you through six steps — Welcome,
Appearance, Search &amp; Privacy, Import, Extensions, Tabs. She arrives at the top of
each question, says what the step is for, and is gone the moment you answer it. You
can skip the whole thing. It runs exactly once: a marker is written when you finish or
skip, and nothing in the app ever removes it.

The Import step reads Chrome, Brave, Edge, Firefox and Safari — bookmarks, history,
home-screen favourites and passwords — straight off disk, per profile. The Extensions
step installs from the verified shortlist below.

### The pet

<img align="right" width="120" src="Internet%20Browser/Internet%20Browser/Features/PearlRunner/Sprites/pearl-sprites.png" alt="Pearl's pixel sprite sheet">

Off by default. Turn on **Keep Pearl on Web Pages** in Settings and she appears on
the pages you browse, at Small, Medium or Large — 1×, 2× or 3× of a 36×40 pixel
drawing, whole multiples only, because a pixel cat at 1.5× loses the one-pixel glint
in her eye.

Drag her anywhere; her position is stored as a fraction of her travel, so she lands
somewhere sensible in a window of any size, and **Send Pearl Home** puts her back in
the bottom-right corner. She blinks, grooms and breathes on a ten-times-a-second
loop, and falls asleep after two minutes of being ignored. Her menu has four rows:
take a screenshot, search for the text you selected, **Give Pearl a Fish**, and put
her away.

She refuses to appear in private windows, on Cherry's own pages, in the unfocused
half of a split view, when the find bar is up, and in a window too small to hold her.

### The game

When a page fails because the network is gone — and only then — the offline screen
carries a runner. Pearl runs, cherry trees and gulls come at her, and it speeds up.
The sky moves every 350 points through day, dusk, night and dawn, and a system `Tink`
sounds at every hundred. It goes quiet if Cherry is not the front app, if you press
**M**, or if you have turned macOS interface sound effects off. Your high score
survives a relaunch.

The sprite sheet on the right is the actual one that ships:
`Features/PearlRunner/Sprites/pearl-sprites.png`, 244×245 pixels, seven flat colours.

---

## The browser

**Tabs.** A Chrome-style strip where tabs resize to fill the bar, drag to reorder,
drag downward to tear a tab into its own window, and drag onto a window edge to open
a split view of two tabs side by side. Coloured, collapsible tab groups. Pinned tabs.
Tab search (⌘⇧A). Hover preview. Inactive tabs sleep after 30 minutes to give the
memory back. An optional vertical tab sidebar (⌘⌥V).

**Pages.** Reader mode, find in page, print, page zoom per tab, view source, a
screenshot command, a QR code for the current URL, and a command palette on ⌘K.
A Develop menu with the WebKit inspector plus Cherry's own Console, Network and
Elements panel.

**The address bar and the new tab page.** The omnibox ranks your history by where
the match landed — typing `git` puts `github.com` above an article whose tracking
parameter happens to contain "git" — and folds in live suggestions from Google or
DuckDuckGo. Five search engines to choose from: Google, DuckDuckGo, Bing, Ecosia,
Brave. The new tab page has a clock, a search field, your own grid of shortcuts, and
one more control: what you type there can go to Pearl instead of to the search engine.
Its background is a wallpaper, a gradient, a curated theme, or a picture of yours.

**Your stuff.** Bookmarks with folders and a bookmark bar, history with search,
downloads, and a password manager that offers to save logins, generates passwords,
fills them on ⌘\, and unlocks with Touch ID or your Mac password. Bookmarks, history
and download records live in Core Data on your machine; the passwords themselves live
in the macOS Keychain, not in that database. Settings, History, Bookmarks, Downloads
and Extensions are real in-tab pages at `cherry://…`, Chrome-style, not floating
windows.

Bookmarks export as Netscape HTML, which Chrome, Firefox, Safari and Edge all read
back — a browser you cannot leave is a trap.

**Privacy.** EasyList and EasyPrivacy are downloaded, reduced to domain block rules
and compiled into WebKit content rules; if a list fails to compile or cannot be
fetched, Settings says so rather than showing a green switch over nothing. A cookie
setting with three positions — allow all, block third-party, block all. Incognito
windows (⌘⇧N) that are never recorded, never themed and never visible to the MCP
server. Focus mode blocks a list of domains you choose, with an optional timer that
defaults to 25 minutes.

**Failures done properly.** Certificate interstitials, HTTP auth prompts and offline
screens are drawn by Cherry, in colours measured against their own background so the
warning text is legible in both light and dark — the certificate tone is an amber-brown
at 7.02:1 rather than `systemRed`, which is 3.55:1 on white and unreadable.

---

## Firefox themes

<p align="center">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/HomepageWallpaperDB283C.imageset/wallpaper-DB283C.jpg" width="30%" alt="Cherry red homepage wallpaper">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/HomepageWallpaper2563EB.imageset/wallpaper-2563EB.jpg" width="30%" alt="Ocean blue homepage wallpaper">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/HomepageWallpaper7C3AED.imageset/wallpaper-7C3AED.jpg" width="30%" alt="Purple homepage wallpaper">
</p>

<p align="center">
  <sub>
    Three of the eight accent wallpapers that ship with the new-tab page, one per
    accent colour, from <code>Assets.xcassets/HomepageWallpaper*.imageset</code>.
  </sub>
</p>

Download a theme `.xpi` from Mozilla, import it in Settings, and Cherry wears it —
an unpacked theme folder works too. The manifest's `theme.colors`
drive the real chrome surfaces and its header artwork is extracted and composited
behind the toolbar with Firefox's own alignment and tiling rules. The theme survives
relaunch. Private windows are never themed.

The part worth the paragraph is what happens when a theme's artwork is busy. Firefox
themes draw every toolbar glyph in one flat `toolbar_text` colour, and one flat colour
cannot stay legible over an illustration — on a real imported theme the incognito icon
landed at **1.33:1** against the bright part of the artwork while the reader icon a few
pixels away sat at 5.10:1, and which icon disappears changes as you resize the window,
because the art is anchored to the window's right edge.

So Cherry re-composites the exact backdrop each cluster of controls is drawn against
into a small offscreen bitmap and measures it — same frame colour, same images, same
anchoring arithmetic — solving for the 10th-percentile pixel inside a sliding
control-sized window. Where the theme is already legible it returns nothing and not one
pixel changes. Where it is not, one surface appears behind the whole cluster, one
colour and one opacity, decided from the worst control under it. Never per control:
a scrim takes its colour from what it is over, so per-control patches read as smudges.

Cherry also carries eight accent colours of its own, and the accent changes the running
app's Dock icon as well as the interface — there is a drawn icon per accent:

<p align="center">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIconAccentDB283C.imageset/AppIconAccentDB283C-512.png" width="64" alt="Cherry Red icon">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIconAccent2563EB.imageset/AppIconAccent2563EB-512.png" width="64" alt="Ocean Blue icon">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIconAccent059669.imageset/AppIconAccent059669-512.png" width="64" alt="Emerald icon">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIconAccent7C3AED.imageset/AppIconAccent7C3AED-512.png" width="64" alt="Purple icon">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIconAccentEA580C.imageset/AppIconAccentEA580C-512.png" width="64" alt="Orange icon">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIconAccentDB2777.imageset/AppIconAccentDB2777-512.png" width="64" alt="Pink icon">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIconAccent0D9488.imageset/AppIconAccent0D9488-512.png" width="64" alt="Teal icon">
  <img src="Internet%20Browser/Internet%20Browser/Assets.xcassets/AppIconAccent6B7280.imageset/AppIconAccent6B7280-512.png" width="64" alt="Graphite icon">
</p>

<p align="center">
  <sub>
    Cherry Red, Ocean Blue, Emerald, Purple, Orange, Pink, Teal, Graphite —
    <code>Assets.xcassets/AppIconAccent&lt;HEX&gt;.imageset</code>. This swaps the
    Dock and ⌘-Tab icon of the running app; the icon Finder shows for
    <code>Cherry.app</code> is baked into the bundle and does not change.
  </sub>
</p>

---

## On-device AI

Open **Ask Pearl** with ⌘⇧K. A panel opens beside the page, and everything in it runs
on your Mac.

| Mode | What it does |
|---|---|
| This page | Answers questions about the page you are looking at. It follows you: navigate or switch tabs and the panel re-reads the new page. |
| These tabs | Pick several open tabs. Cherry chunks them, indexes every chunk twice — densely with `NLContextualEmbedding`, lexically with BM25 — fuses the two rankings, and answers with `[n]` citations back to the tab each passage came from. If the embedding assets are not on the Mac it falls back to BM25 alone rather than failing. |
| Web | One DuckDuckGo search, the top results opened as background tabs in a locked group called "AI", read, indexed and answered with citations. Read-only by construction: it opens result URLs and reads them, and does nothing else. |

Two engines, chosen in the panel:

- **Apple** — Apple's Foundation Models framework. **Needs Apple Intelligence turned on
  in System Settings, on a Mac eligible for it.** If it is off or the Mac is not
  eligible, the panel says which of the two it is instead of failing quietly.
- **Qwen (Local)** — `mlx-community/Qwen3-8B-4bit`, run through MLX. The weights are a
  multi-gigabyte download that only ever starts when you ask for it in Settings, and
  they go to Application Support, not your Downloads folder. MLX is Apple's
  Apple-silicon framework, so this engine wants an Apple-silicon Mac.

Pearl is who you are talking to, and she is told not to pretend: she cannot browse,
click, remember other conversations, or know anything that is not in front of her, and
every mode has to state what she says when she does not know.

---

## MCP server

Settings → MCP, off until you switch it on. Cherry then listens on `127.0.0.1:8787`
and serves nine tools over streamable HTTP behind a bearer token, and gives you the
exact registration command to paste:

```
claude mcp add --transport http --scope user cherry http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer $(cat …)"
```

Codex is registered with `codex mcp add cherry --url … --bearer-token-env-var
CHERRY_MCP_TOKEN`, and the pane tells you why that one also needs a line in your shell
profile.

| Tool | What it does |
|---|---|
| `list_tabs` | Every open tab across non-private windows: id, title, URL, window, and whether it is selected, pinned, sleeping or loading. Titles and URLs only, never page text. |
| `read_page` | The readable text of one open tab, in chunks. Refuses with a reason for a sleeping tab, a PDF, a `cherry://` page, or a tab never displayed. |
| `read_elements` | The clickable and typeable things on a page, numbered. Viewport by default; `scope: "page"` or a substring `filter` for more. |
| `request_action_session` | Asks **you**, in a dialog naming the tab, the site and what the caller says it intends to do. Up to 30 minutes, one tab. |
| `click_element` | Clicks one numbered element. Needs a live session, the matching document id, and the element's name to still match. |
| `type_text` | Types into one numbered field the way a person does, so the page's own JavaScript reacts. Refuses password fields outright. |
| `search_history` | Case-insensitive substring search over your history titles and URLs. Never sees private windows. |
| `search_bookmarks` | The same over your bookmarks, with the folder each is filed under. |
| `open_tab` | Opens an `http`/`https` URL in a new tab. More than five a minute is refused. |

What the design is careful about:

- **Nothing acts without you saying yes.** Reading is free; clicking and typing need a
  session you granted in a dialog. The grant is one tab, one requester, one origin, one
  clock — a cross-origin navigation ends it, so does closing the tab, so does quitting.
  It is never written to disk, so a restart revokes it.
- **Cherry refuses to click things that look irreversible** — send, buy, pay, delete,
  transfer, publish — and hands them back to you. That check is a heuristic over English
  words and HTML shape, and the code says so plainly: it misses icon-only buttons, every
  non-English page, and anything labelled "Continue" or "Next".
- **The token stops a web page.** Any site you visit could otherwise `fetch` a localhost
  server. The token is 32 random bytes in a `0600` file; it does not stop anything else
  running as you, and the code does not pretend it does.
- **Private windows do not exist** to any of this. Not their tabs, not their history,
  not the fact that they are open.
- **The socket dies with your last window** and comes back with the next one, so closing
  every window cannot leave a browser serving your history as a headless daemon.

---

## Extensions

Cherry loads WebExtensions through `WKWebExtensionController` — File → Load Extension…,
or from the first-run wizard. Installed extensions are copied into an app-managed
directory and come back on the next launch.

The wizard offers exactly three, because exactly three were put through a verification
harness in Cherry's own runtime on 2026-08-12 and observed doing their job. Loading
cleanly was never accepted as passing.

| Extension | Verified | The caveat, as the wizard shows it |
|---|---|---|
| **uBO Lite** | 2026.804.1652 (Firefox build) | Needs ~90 seconds to warm up; first blocks land around ten seconds in. Even then one of its six lists (easylist) registers but never takes effect, so some ads get through. |
| **Dark Reader** | 4.9.129 | None. |
| **Simple Translate** | 3.0.1 | The toolbar popup works. The floating button on selected text did not work reliably in Cherry. |

Ten candidates went in. The seven that did not survive are listed in
`ExtensionShortlist.swift` with the mechanism behind each rejection — including full
uBlock Origin, whose MV2 blocking simply cannot work here: WebKit delivers
`webRequest` events but discards the listener's return value, and never grants
`webRequestBlocking` at all. Nothing Cherry can bridge.

---

## Getting it

There is no download link here yet. Cherry cannot be signed on the machine it is built
on, so a published DMG would greet whoever clicked it with a security block and no
explanation — see the next section for exactly what that looks like. The script that
makes the DMG is in the repository, and the decision to put one somewhere people can
click is the author's to make.

### Build the DMG yourself

```sh
git clone <this repo> && cd <it>
./Tools/build-dmg.sh
```

That produces `dist/Cherry-1.0.dmg` — a Release build, ad-hoc signed, universal
(`x86_64 arm64`), around **39 MB**, containing exactly two things: `Cherry.app` and a
symlink to `/Applications`. The script builds into a throwaway directory under
`/private/tmp` and deletes it on any exit, strips the debug map so the app does not
carry the builder's home directory around inside it, refuses to build an image
containing databases, tokens, keys or user defaults, prints the image's SHA-256, and
prints the same warning you are about to read.

It needs Xcode 26, and takes several minutes the first time because MLX compiles from
source. You can also just open `Internet Browser/Internet Browser.xcodeproj` and press
⌘R.

### Gatekeeper: if someone hands you the DMG

**Read this part.** It is not optional and it is not a formality.

This machine has no Apple code-signing identity — `security find-identity -v -p
codesigning` returns *0 valid identities* — so Cherry cannot be signed with a Developer
ID and cannot be notarized. It is signed ad-hoc, which is enough to run where it was
built and not enough anywhere else.

Here is what actually happens. This was measured on **macOS 26.5.2**, on a copy of the
DMG carrying the same quarantine flag Safari writes when a download finishes, with the
app copied out of the mounted image the way you would copy it:

1. **The DMG mounts and copies fine.** Dragging Cherry to Applications works. Nothing
   warns you yet. The quarantine flag comes along with the app.
2. **Then it does not open.** macOS copies the app into a random read-only folder
   (App Translocation), checks the signature, does not like it, puts a security dialog
   in front of you, and kills the process. The system's own log for that attempt:

   ```
   amfid:      Cherry not valid: … Code=-423 "The file is adhoc signed or
               signed by an unknown certificate chain"
   syspolicyd: GatekeeperPolicyScanError Code=-67018
               "Code did not match any currently allowed policy"
   syspolicyd: Prompt shown (6, 0), waiting for response
   syspolicyd: Adding Gatekeeper denial breadcrumb (open)
   syspolicyd: Terminating process due to Gatekeeper rejection
   ```

   macOS keeps two sentences for this case, and both are in its own string table:
   *"'Cherry' is damaged and can't be opened"* and *"Apple could not verify 'Cherry' is
   free of malware that may harm your Mac"*, next to a **Move to Trash** button.
   **Cherry is not damaged and is not malware.** That is what macOS says about any app
   with no Developer ID, and it says it in the strongest words it has.
3. **The fix that was verified**, on that quarantined copy, one command:

   ```sh
   xattr -d com.apple.quarantine /Applications/Cherry.app
   ```

   Then open it normally. Measured immediately after: it launched from its own path,
   with no dialog and no Gatekeeper rejection in the log. (Files *inside* the bundle
   keep their own copies of the flag — 34 of them — and that does not stop the launch.
   `xattr -dr` clears those too if you want it tidy.)

That command removes the "downloaded from the internet" mark. You are telling your Mac
you trust this app because of where you got it, not because Apple checked it — a real
decision, and one to make only for a build from someone you trust or one you built
yourself from this source.

Two things this README will not claim, because they were not tested: **right-click →
Open**, and the **Open Anyway** button that appears in System Settings → Privacy &
Security after a blocked launch. Both are mouse routes and this was measured from a
terminal. macOS did write the denial breadcrumb that makes the Settings button appear,
so that route very likely works; the `xattr` command is the one with evidence behind it.

**What would fix it properly:** a paid Apple Developer Program membership, a Developer
ID Application certificate in the keychain, and an `xcrun notarytool submit` pass on
every build. Then the DMG opens on one click — no terminal, no warning, no explaining.
None of that exists on the machine this was built on, so none of it is faked here.

---

## Keyboard shortcuts

Every shortcut in Cherry is declared once, in the menu bar, so each one has a real
menu item behind it.

| | | | |
|---|---|---|---|
| ⌘T | New Tab | ⌘F | Find in Page |
| ⌘N | New Window | ⌘K | Command Palette |
| ⌘⇧N | New Incognito Window | ⌘⇧K | Ask Pearl |
| ⌘W | Close Tab | ⌘\ | Auto-Fill Password |
| ⌘⇧T | Reopen Last Closed Tab | ⌘R | Reload |
| ⌘1…⌘8 | Show that tab | ⌘. | Stop |
| ⌘9 | Show last tab | ⌘[ / ⌘] | Back / Forward |
| ⌃⇥ / ⌃⇧⇥ | Next / previous tab | ⌘0 / ⌘= / ⌘- | Zoom |
| ⌘⇧A | Search Tabs | ⌘⇧R | Toggle Reader |
| ⌘L | Focus Address Bar | ⌘P | Print |
| ⌘D | Add Bookmark | ⌘⌥4 | Take Screenshot |
| ⌘⌥B | Show All Bookmarks | ⌘⇧F | Toggle Focus Mode |
| ⌘⇧B | Toggle Bookmark Bar | ⌘⌥I | Web Inspector |
| ⌘Y | Show All History | ⌘⌥C | JavaScript Console |
| ⌘⇧J | Show Downloads | ⌘U | View Page Source |
| ⌘⌥V | Toggle Vertical Tabs | ⌘⇧\ | Toggle Split View |
| ⌘, | Settings | | |

---

## What it needs, and what it is

- **macOS 26.2 or later.** Not a preference — it is the deployment target, and Cherry
  will not launch below it.
- **Apple Intelligence**, separately, for the Apple engine behind Ask Pearl. The Qwen
  engine wants an Apple-silicon Mac and a download you start yourself.
- **Xcode 26** to build it.
- A personal project, by one person, with no company behind it and no support promise.
  It is not sandboxed, it is not on the App Store, and it is not notarized.
- The engine is `WKWebView`. Cherry does not have its own renderer, so its page
  compatibility is Safari's page compatibility — including where that is worse than
  Chrome's.

Written in Swift and SwiftUI, state through `@Observable`, storage in Core Data.
Two dependencies, both Swift packages: the official
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) and
[mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) for the local
Qwen engine. `PROJECT_PROGRESS.md` is the long version, feature by feature.

## License

All rights reserved.
