# Cherry Browser - Project Progress

## Overview
Cherry is a privacy-focused, local-only macOS web browser built with SwiftUI and WKWebView. All data stays on device - no cloud sync, no accounts.

## Tech Stack
- **UI Framework**: SwiftUI (macOS 26.2+)
- **Rendering Engine**: WKWebView
- **Data Persistence**: Core Data (local only)
- **Password Storage**: macOS Keychain (encrypted)
- **Architecture**: MVVM with @Observable

---

## Phase 1: Core Browser Foundation ✅ COMPLETE

### Implemented Features
- [x] Project structure with MVVM architecture
- [x] WKWebView wrapper (NSViewRepresentable)
- [x] Tab management (create, close, switch, reorder)
- [x] Navigation bar with Omnibox
- [x] Back/Forward/Reload/Stop controls
- [x] URL parsing with smart URL vs search detection
- [x] Search engine integration (Google default)
- [x] Tab bar with favicon, title, close button
- [x] Loading progress bar
- [x] Modern Safari user-agent (for full website compatibility)
- [x] Keyboard shortcuts

### Keyboard Shortcuts (Phase 1)
| Shortcut | Action |
|----------|--------|
| Cmd+T | New Tab |
| Cmd+W | Close Tab |
| Cmd+Shift+T | Reopen Closed Tab |
| Cmd+R | Reload |
| Cmd+[ | Go Back |
| Cmd+] | Go Forward |
| Cmd+L | Focus Address Bar |
| Cmd+1-9 | Switch to Tab |
| Ctrl+Tab | Next Tab |
| Ctrl+Shift+Tab | Previous Tab |

### Files Created
```
Internet Browser/
├── Core/
│   ├── Constants/
│   │   └── AppConstants.swift
│   └── Extensions/
│       └── URL+Extensions.swift
├── Features/
│   ├── Browser/
│   │   ├── Models/
│   │   │   └── Tab.swift
│   │   ├── Views/
│   │   │   ├── BrowserView.swift
│   │   │   └── WebViewWrapper.swift
│   │   └── ViewModels/
│   │       └── BrowserViewModel.swift
│   ├── Tabs/
│   │   ├── Views/
│   │   │   ├── TabBarView.swift
│   │   │   └── TabItemView.swift
│   │   └── ViewModels/
│   │       └── TabManager.swift
│   └── Navigation/
│       └── Views/
│           ├── NavigationBarView.swift
│           └── OmniboxView.swift
└── Internet_Browser.entitlements
```

---

## Phase 2: Data Persistence ✅ COMPLETE

### Implemented Features
- [x] Core Data model (programmatic, no .xcdatamodeld)
- [x] Bookmark repository with CRUD operations
- [x] History repository with auto-save
- [x] Bookmark bar (toggleable)
- [x] Bookmarks sidebar with search and folder filtering
- [x] History sidebar with grouped entries (Today, Yesterday, etc.)
- [x] Add bookmark dialog
- [x] Clear history functionality (Last Hour, Today, All Time)
- [x] Context menus for bookmarks and history items

### Keyboard Shortcuts (Phase 2)
| Shortcut | Action |
|----------|--------|
| Cmd+D | Add Bookmark |
| Cmd+Y | Toggle History |
| Cmd+Shift+B | Toggle Bookmarks |
| Cmd+Option+B | Toggle Bookmark Bar |

### Files Created
```
Internet Browser/
├── Data/
│   ├── CoreData/
│   │   └── PersistenceController.swift
│   ├── Models/
│   │   ├── BookmarkEntity.swift
│   │   └── HistoryEntity.swift
│   └── Repositories/
│       ├── BookmarkRepository.swift
│       └── HistoryRepository.swift
├── Features/
│   ├── Bookmarks/
│   │   └── Views/
│   │       ├── BookmarkBarView.swift
│   │       ├── BookmarksSidebarView.swift
│   │       └── AddBookmarkView.swift
│   └── History/
│       └── Views/
│           └── HistoryView.swift
```

---

## Phase 3: Tab Bar, Homepage & UI Polish ✅ COMPLETE

### Implemented Features
- [x] Tab bar inline with native macOS traffic lights (Chrome-like layout)
- [x] Hidden titlebar with fullscreen mode support
- [x] Fullscreen-aware tab bar (adapts padding for traffic lights)
- [x] Homepage with Cherry logo and "Cherry" branding
- [x] Animated MeshGradient background (cherry red theme)
- [x] Responsive homepage layout (adapts to window size)
- [x] Homepage shortcuts with auto favicon fetching (Google favicon API)
- [x] Default shortcuts (Google, YouTube, GitHub, Twitter, Reddit, Wikipedia)
- [x] Shortcut CRUD with CoreData persistence
- [x] Fixed sidebar close buttons (History & Bookmarks)
- [x] Window drag support via isMovableByWindowBackground
- [x] Explicit tab text visibility with foreground styling

### Files Created/Modified
```
Internet Browser/
├── Assets.xcassets/
│   └── CherryLogo.imageset/          (NEW)
│       ├── CherryLogo.png
│       └── Contents.json
├── Data/
│   ├── Models/
│   │   └── ShortcutEntity.swift       (NEW)
│   └── Repositories/
│       └── ShortcutRepository.swift   (NEW)
├── Features/
│   ├── HomePage/
│   │   └── Views/
│   │       └── HomePageView.swift     (NEW)
│   ├── Browser/Views/BrowserView.swift (MODIFIED)
│   ├── Tabs/Views/TabBarView.swift    (MODIFIED)
│   └── Tabs/Views/TabItemView.swift   (MODIFIED)
└── Internet_BrowserApp.swift          (MODIFIED)
```

---

## Phase 4: Enhanced Tab Management ✅ COMPLETE

### Implemented Features
- [x] Context menu actions fully wired (New Tab, Duplicate, Pin/Unpin, Close Others, Close Right)
- [x] Drag-and-drop tab reordering (horizontal and vertical tab bars)
- [x] Tab groups with colors (8 colors: red, orange, yellow, green, blue, purple, pink, gray)
- [x] Tab group collapse/expand with group chip display
- [x] Tab group context menu (Add to New Group, Add to Group, Remove from Group)
- [x] Tab search overlay (Cmd+Shift+A) with filtering by title/URL
- [x] Tab preview on hover (delayed popover with title, URL, sleep status)
- [x] Vertical tab bar option (Cmd+Option+V to toggle, collapsible sidebar)
- [x] Tab sleeping (auto-sleep after 30min inactive, releases WebView for memory)
- [x] Sleeping tabs: dimmed visual indicator, moon icon, wake on select
- [x] Pinned tabs excluded from auto-sleep
- [x] Vertical tab bar preference persisted via UserDefaults

### Keyboard Shortcuts (Phase 4)
| Shortcut | Action |
|----------|--------|
| Cmd+Shift+A | Toggle Tab Search |
| Cmd+Option+V | Toggle Vertical Tab Bar |

### Files Created/Modified
```
Internet Browser/
├── Features/
│   ├── Tabs/
│   │   ├── Models/
│   │   │   └── TabGroup.swift              (NEW)
│   │   ├── Views/
│   │   │   ├── TabBarView.swift            (MODIFIED)
│   │   │   ├── TabItemView.swift           (MODIFIED)
│   │   │   ├── TabSearchView.swift         (NEW)
│   │   │   └── VerticalTabBarView.swift    (NEW)
│   │   └── ViewModels/
│   │       └── TabManager.swift            (MODIFIED)
│   └── Browser/
│       ├── Models/
│       │   └── Tab.swift                   (MODIFIED)
│       ├── Views/
│       │   └── BrowserView.swift           (MODIFIED)
│       └── ViewModels/
│           └── BrowserViewModel.swift      (MODIFIED)
```

---

## Phase 5: Settings & Privacy ✅ COMPLETE

### Implemented Features
- [x] Centralized SettingsManager (@Observable singleton backed by UserDefaults)
- [x] Settings window (Cmd+,) with tabbed layout (General, Privacy, About)
- [x] Search engine selection (Google, Bing, DuckDuckGo, Yahoo, Ecosia)
- [x] Homepage URL configuration
- [x] Bookmark bar toggle in settings
- [x] Vertical tabs toggle in settings
- [x] Tab sleep settings (enable/disable, timeout in minutes)
- [x] JavaScript toggle (applies to new WKWebView instances)
- [x] HTTPS-only mode (upgrades known hosts to HTTPS)
- [x] Cookie blocking (None, Third-party, All)
- [x] Do Not Track header option
- [x] Clear browsing data UI (History, Cookies & Site Data, Cache)
- [x] Time-range clearing (Last Hour, Last 24 Hours, All Time)
- [x] Private browsing mode (Cmd+Shift+N for new private window)
- [x] Private mode uses ephemeral WKWebsiteDataStore (no data persisted)
- [x] Private mode skips history recording
- [x] Purple tab bar indicator for private browsing windows
- [x] About tab with app name, version, and build info
- [x] Chrome-style dynamic tab sizing (tabs fill available space, shrink as more added)
- [x] AppKit-based window drag areas (prevents drag conflict with tab reorder)
- [x] Drop-based tab reorder (smooth animation, no oscillation)

### Keyboard Shortcuts (Phase 5)
| Shortcut | Action |
|----------|--------|
| Cmd+, | Open Settings |
| Cmd+Shift+N | New Private Window |

### Files Created/Modified
```
Internet Browser/
├── Core/
│   └── Views/
│       └── WindowDragAreaView.swift         (NEW)
├── Features/
│   ├── Settings/
│   │   ├── ViewModels/
│   │   │   └── SettingsManager.swift        (NEW)
│   │   └── Views/
│   │       ├── SettingsView.swift           (NEW)
│   │       ├── GeneralSettingsView.swift    (NEW)
│   │       ├── PrivacySettingsView.swift    (NEW)
│   │       ├── ClearDataView.swift          (NEW)
│   │       └── AboutSettingsView.swift      (NEW)
│   ├── Browser/
│   │   ├── Models/
│   │   │   └── Tab.swift                    (MODIFIED - added isPrivate)
│   │   ├── Views/
│   │   │   ├── BrowserView.swift            (MODIFIED - private mode, WindowConfigurator)
│   │   │   └── WebViewWrapper.swift         (MODIFIED - privacy settings)
│   │   └── ViewModels/
│   │       └── BrowserViewModel.swift       (MODIFIED - uses SettingsManager, private windows)
│   └── Tabs/Views/
│       └── TabBarView.swift                 (MODIFIED - Chrome-style sizing, private mode indicator)
├── Data/
│   └── Repositories/
│       └── HistoryRepository.swift          (MODIFIED - time-range clearing)
└── Internet_BrowserApp.swift                (MODIFIED - added Settings scene)
```

---

## Phase 6: Theme Settings, Ad Blocker & UI Refinements ✅ COMPLETE

### Implemented Features
- [x] Theme/accent color selection in settings
- [x] Ad blocker with cosmetic filtering
- [x] Per-site ad blocker pause/resume (shield icon in toolbar)
- [x] 3-dot menu in navigation bar (Bookmarks, History, Downloads, Settings)
- [x] Settings page redesign with sidebar navigation
- [x] UI refinements and polish

### Files Modified
```
Internet Browser/
├── Features/
│   ├── Settings/
│   │   └── Views/
│   │       └── SettingsPageView.swift       (NEW)
│   ├── Navigation/
│   │   └── Views/
│   │       └── NavigationBarView.swift      (MODIFIED - 3-dot menu, ad block toggle)
│   └── Browser/
│       └── Views/
│           └── WebViewWrapper.swift         (MODIFIED - ad blocker integration)
```

---

## Phase 7: Incognito Mode, Drag-and-Drop & Performance ✅ COMPLETE

### Implemented Features
- [x] Chrome-like tab drag-and-drop with animated insertion indicator
- [x] Incognito/private browsing mode toggle in toolbar
- [x] Dock menu integration
- [x] Performance optimizations for tab management
- [x] Animated tab insertion indicator during drag reorder

---

## Phase 8: Download Manager ✅ COMPLETE

### Implemented Features
- [x] Cosmetic ad blocking improvements
- [x] Download manager with progress tracking
- [x] Download sidebar with file list
- [x] Download toast notifications
- [x] Pause/resume/cancel downloads
- [x] Open downloaded files / show in Finder

### Files Created/Modified
```
Internet Browser/
├── Data/
│   ├── Models/
│   │   └── DownloadItem.swift               (NEW)
│   └── Repositories/
│       └── DownloadRepository.swift         (NEW)
├── Features/
│   └── Downloads/
│       ├── ViewModels/
│       │   └── DownloadManager.swift        (NEW)
│       └── Views/
│           ├── DownloadsSidebarView.swift   (NEW)
│           └── DownloadToastView.swift      (NEW)
```

---

## Phase 9: Password Manager, Omnibox Autocomplete & Downloads ✅ COMPLETE

### Implemented Features

#### Password Manager
- [x] Keychain-backed secure password storage (no plaintext on disk)
- [x] Password auto-fill detection for login forms
- [x] Auto-fill popup with matching credentials
- [x] Save password banner when new credentials detected
- [x] Password generator (configurable length, uppercase, numbers, symbols)
- [x] Passwords settings/management UI
- [x] Key icon in toolbar when login form detected (Cmd+\)
- [x] Core Data metadata + Keychain hybrid storage

#### Omnibox Autocomplete
- [x] Google search suggestions (autocomplete API)
- [x] History-based suggestions (show previously visited URLs)
- [x] History suggestions appear instantly, search suggestions debounced (300ms)
- [x] Floating dropdown with material background and shadow
- [x] Keyboard navigation (Up/Down arrows to cycle, Enter to select, Escape to dismiss)
- [x] Mouse hover highlighting
- [x] URL detection (skips search suggestions for URL-like input, still shows history)
- [x] History items shown with clock icon + page title + URL subtitle
- [x] Search items shown with magnifying glass icon

#### Download Improvements
- [x] QuickLook preview support for downloaded files

### Keyboard Shortcuts (Phase 9)
| Shortcut | Action |
|----------|--------|
| Cmd+\ | Auto-fill Password |
| Up/Down | Navigate suggestions in omnibox |
| Escape | Dismiss suggestions |

### Files Created/Modified
```
Internet Browser/
├── Core/
│   └── Security/
│       └── KeychainHelper.swift                  (NEW)
├── Data/
│   ├── Models/
│   │   └── PasswordItem.swift                    (NEW)
│   └── Repositories/
│       └── PasswordRepository.swift              (NEW)
├── Features/
│   ├── Passwords/
│   │   ├── ViewModels/
│   │   │   ├── PasswordManager.swift             (NEW)
│   │   │   ├── PasswordGenerator.swift           (NEW)
│   │   │   └── PasswordAutoFillScripts.swift     (NEW)
│   │   └── Views/
│   │       ├── PasswordAutoFillPopup.swift       (NEW)
│   │       ├── PasswordsSettingsView.swift       (NEW)
│   │       └── SavePasswordBanner.swift          (NEW)
│   ├── Navigation/
│   │   ├── ViewModels/
│   │   │   └── SearchSuggestService.swift        (NEW)
│   │   └── Views/
│   │       ├── OmniboxSuggestionsView.swift      (NEW)
│   │       ├── OmniboxView.swift                 (MODIFIED - onTextChange, onBlur, arrow key callbacks)
│   │       └── NavigationBarView.swift           (MODIFIED - suggestion integration, keyboard nav)
│   └── Downloads/
│       └── ViewModels/
│           └── DownloadQuickLookHelper.swift     (NEW)
```

---

## Phase 10: Find in Page, Print, Reader Mode, PiP, Screenshots, QR Code, PDF ✅ COMPLETE

### Implemented Features
- [x] Find in Page (Cmd+F) with match highlighting and prev/next navigation
- [x] Print / Save as PDF (Cmd+P)
- [x] Reader Mode (Cmd+Shift+R) — extracts article content and renders distraction-free
- [x] Picture-in-Picture for video — floats video in a resizing panel
- [x] Screenshot capture (Cmd+Shift+4) — saves to Downloads folder with toast
- [x] QR Code generation for current page URL
- [x] PDF download via WKDownload

### Keyboard Shortcuts (Phase 10)
| Shortcut | Action |
|----------|--------|
| Cmd+F | Find in Page |
| Cmd+P | Print / Save as PDF |
| Cmd+Shift+R | Toggle Reader Mode |
| Cmd+Shift+4 | Capture Screenshot |

### Files Created/Modified
```
Internet Browser/
├── Features/
│   └── Browser/
│       └── Views/
│           ├── FindInPageBar.swift           (NEW)
│           ├── ReaderModeView.swift          (NEW)
│           └── QRCodePopup.swift             (NEW)
│   └── Browser/
│       └── ViewModels/
│           └── ReaderModeExtractor.swift     (NEW)
```

---

## Phase 11: Glass UI, Tab Tear-Off & Cross-Window Transfer ✅ COMPLETE

### Implemented Features
- [x] Glassmorphism UI — `.ultraThinMaterial`/`.thinMaterial` for tab bar, nav bar, omnibox, sidebar
- [x] Transparent window background for true vibrancy
- [x] Hairline dividers (0.5pt, adaptive opacity) replacing hard Divider()
- [x] Tab tear-off: drag tab vertically out of bar to open in new window
- [x] Ghost drag visual: tab slot dims to 35%, floating copy follows cursor
- [x] Cross-window re-attach: drop torn-off tab onto existing window to merge
- [x] Window registry (`windowViewModels` dict, `associatedWindow`) for cursor-based window hit-testing
- [x] `WindowRegistrar` NSViewRepresentable to capture NSWindow reference in SwiftUI

### Files Created/Modified
```
Internet Browser/
├── Features/
│   ├── Browser/
│   │   └── Views/
│   │       └── BrowserView.swift             (MODIFIED - WindowRegistrar, glass dividers, onDrop)
│   │   └── ViewModels/
│   │       └── BrowserViewModel.swift        (MODIFIED - associatedWindow, detachTab rewrite)
│   ├── Tabs/
│   │   └── Views/
│   │       ├── TabBarView.swift              (MODIFIED - ghost drag states, DragGesture tear-off)
│   │       ├── TabItemView.swift             (MODIFIED - glass tabBackground, removed onDrag)
│   │       └── VerticalTabBarView.swift      (MODIFIED - glass sidebar)
│   └── Navigation/
│       └── Views/
│           ├── NavigationBarView.swift       (MODIFIED - glass nav bar)
│           └── OmniboxView.swift             (MODIFIED - glass pill)
```

---

## Phase 12: Session Restore & Command Palette ✅ COMPLETE

### Implemented Features

#### Session Restore
- [x] Automatically saves all non-private tabs on quit (`applicationWillTerminate`)
- [x] Restores previous session on launch if setting is enabled
- [x] Restores previously active tab index
- [x] Setting toggle in General → Tabs preferences
- [x] Private/incognito windows excluded from session save
- [x] Persisted via `UserDefaults` as a JSON-encoded array of `SavedTabEntry`

#### Command Palette (Cmd+K)
- [x] Full-screen dimmed overlay with glass card (`.regularMaterial`)
- [x] Auto-focused search field with live filtering
- [x] Grouped result sections: Open Tabs, Bookmarks, History, Actions
- [x] Keyboard navigation: Up/Down arrows to move, Enter to execute, Escape to close
- [x] `ScrollViewReader` keeps selected row visible
- [x] "No results" empty state when query has no matches
- [x] Accent-tinted selection highlight row

### Keyboard Shortcuts (Phase 12)
| Shortcut | Action |
|----------|--------|
| Cmd+K | Open Command Palette |
| Up/Down | Navigate results |
| Enter | Execute selected result |
| Escape | Close palette |

### Files Created/Modified
```
Internet Browser/
├── Data/
│   └── Repositories/
│       └── SessionRestoreManager.swift       (NEW)
├── Features/
│   ├── Browser/
│   │   ├── ViewModels/
│   │   │   └── BrowserViewModel.swift        (MODIFIED - showCommandPalette, restoreSessionIfNeeded, saveSessionForRestore)
│   │   └── Views/
│   │       ├── BrowserView.swift             (MODIFIED - commandPaletteOverlay, Cmd+K, Escape, onAppear restore)
│   │       └── CommandPaletteView.swift      (NEW)
│   └── Settings/
│       ├── ViewModels/
│       │   └── SettingsManager.swift         (MODIFIED - restorePreviousSession)
│       └── Views/
│           └── GeneralSettingsView.swift     (MODIFIED - restore session toggle)
└── Internet_BrowserApp.swift                 (MODIFIED - applicationWillTerminate, Cmd+K menu item, notification name)
```

---

## Phase 13: Developer Tools ✅ COMPLETE

### Implemented Features
- [x] Web Inspector enabled — `isInspectable = true` on every WKWebView; attach via Develop > Show Web Inspector in macOS menu bar
- [x] JS Console panel — captures `console.log/info/warn/error` via injected WKUserScript bridge; live-scrolling list with monospaced output, color-coded by level, timestamp per entry, filter pills (All / Log / Info / Warn / Error), clear button
- [x] Network log panel — captures main-frame HTTP navigations (method, URL, status code, response time) via WKNavigationDelegate; XHR + fetch subresource tracking via injected JS interceptor; color-coded method + status columns, URL filter, timing display
- [x] Bottom-docked panel, 240pt tall, full-width inside browser content area
- [x] Cmd+Option+I to toggle Dev Tools panel, Cmd+Option+C to open Console tab
- [x] Escape closes panel (after Command Palette, before Find in Page)
- [x] View Page Source (Cmd+U) — opens `view-source:` URL in a new tab
- [x] Wired up existing "Show Web Inspector" and "Show JavaScript Console" menu items

### Keyboard Shortcuts (Phase 13)
| Shortcut | Action |
|----------|--------|
| Cmd+Option+I | Toggle Dev Tools panel |
| Cmd+Option+C | Open Console tab |
| Cmd+U | View Page Source |
| Escape | Close Dev Tools panel |

### Files Created/Modified
```
Internet Browser/
├── Data/
│   └── Models/
│       ├── ConsoleEntry.swift                (NEW)
│       └── NetworkEntry.swift                (NEW)
├── Features/
│   └── Browser/
│       ├── ViewModels/
│       │   ├── DevToolsManager.swift         (NEW)
│       │   └── ConsoleScripts.swift          (NEW)
│       └── Views/
│           ├── DevToolsPanelView.swift       (NEW)
│           ├── WebViewWrapper.swift          (MODIFIED - isInspectable, console/network scripts, message handlers, nav timing)
│           └── BrowserView.swift             (MODIFIED - panel in BrowserContentView, shortcuts, notifications)
│   └── Browser/
│       └── ViewModels/
│           └── BrowserViewModel.swift        (MODIFIED - showDevToolsPanel, toggleDevTools)
```

---

## Phase 14: Focus Mode / Site Blocker ✅ COMPLETE

### Implemented Features
- [x] `FocusModeManager` — `@Observable` singleton with UserDefaults persistence
- [x] Per-domain block list — add/remove domains, wildcard subdomain matching
- [x] Focus mode toggle — Cmd+Shift+F keyboard shortcut + brain icon in toolbar
- [x] Session timer — optional countdown (15/25/30/45/60/90/120 min), auto-stops focus mode on expiry
- [x] 5-minute override — "Allow for 5 minutes" bypasses a specific domain temporarily
- [x] Full-screen block page — dark glass overlay with countdown timer, override and disable buttons
- [x] Navigation interception — `decidePolicyFor` in WebViewWrapper cancels blocked navigations
- [x] Focus Settings tab — full blocked sites manager, quick-add for common social/video sites
- [x] Quick-block grid — toggle Twitter, Reddit, YouTube, Instagram, Facebook, TikTok, Netflix, LinkedIn with one tap
- [x] Re-navigation on override/disable — navigates to the originally blocked URL after unblocking

### Keyboard Shortcuts (Phase 14)
| Shortcut | Action |
|----------|--------|
| Cmd+Shift+F | Toggle Focus Mode |

### Files Created/Modified
```
Internet Browser/
├── Features/
│   └── Focus/
│       ├── ViewModels/
│       │   └── FocusModeManager.swift          (NEW)
│       └── Views/
│           ├── FocusBlockView.swift             (NEW)
│           └── FocusModeSettingsView.swift      (NEW)
├── Features/
│   ├── Settings/
│   │   └── Views/
│   │       └── SettingsView.swift               (MODIFIED - Focus tab added)
│   ├── Navigation/
│   │   └── Views/
│   │       └── NavigationBarView.swift          (MODIFIED - brain icon button)
│   └── Browser/
│       ├── ViewModels/
│       │   └── BrowserViewModel.swift           (MODIFIED - showFocusBlock, focusBlockedHost/URL, toggleFocusMode)
│       └── Views/
│           ├── BrowserView.swift                (MODIFIED - focusBlockOverlay, siteBlocked notification, Cmd+Shift+F)
│           └── WebViewWrapper.swift             (MODIFIED - decidePolicyFor blocks Focus domains)
└── Internet_BrowserApp.swift                    (MODIFIED - siteBlocked, focusModeSessionEnded notification names)
```

---

## Future Phases ⏳ PENDING

### Additional Features
- [ ] Extensions/plugin system
- [ ] Tab workspaces

---

## Build & Run

### Requirements
- macOS 26.2+
- Xcode 17+

### Entitlements
- Network client access (outgoing connections)
- File access (downloads)

### To Build
1. Open `Internet Browser.xcodeproj` in Xcode
2. Select the "Internet Browser" scheme
3. Build and run (Cmd+R)

---

## Data Storage

All data is stored locally:
```
~/Library/Application Support/Cherry/
└── CherryBrowser.sqlite       (bookmarks, history, shortcuts, download metadata, password metadata)

macOS Keychain
└── com.cherry.browser.passwords   (encrypted passwords)
```

No cloud sync. No accounts. Your data stays on your device.

---

## License

Private project.
