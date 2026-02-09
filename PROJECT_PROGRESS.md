# Cherry Browser - Project Progress

## Overview
Cherry is a privacy-focused, local-only macOS web browser built with SwiftUI and WKWebView. All data stays on device - no cloud sync, no accounts.

## Tech Stack
- **UI Framework**: SwiftUI (macOS 26.2+)
- **Rendering Engine**: WKWebView
- **Data Persistence**: Core Data (local only)
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

## Phase 6: Downloads Manager ⏳ PENDING

### Planned Features
- [ ] Download progress tracking
- [ ] Pause/resume/cancel
- [ ] Download history
- [ ] Quick Look integration

---

## Phase 7: Password Manager ⏳ PENDING

### Planned Features
- [ ] Keychain integration
- [ ] Auto-fill login forms
- [ ] Password generator
- [ ] Touch ID integration

---

## Phase 8: Developer Tools ⏳ PENDING

### Planned Features
- [ ] WebKit Inspector integration
- [ ] Console access
- [ ] Network panel

---

## Phase 9: Additional Features ⏳ PENDING

### Planned Features
- [ ] Reading mode
- [ ] Screenshots (visible area, full page)
- [ ] Print/PDF
- [ ] Picture-in-Picture
- [ ] QR code generation

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

All data is stored locally in:
```
~/Library/Application Support/Cherry/
└── Cherry.sqlite
```

No cloud sync. No accounts. Your data stays on your device.

---

## License

Private project.
