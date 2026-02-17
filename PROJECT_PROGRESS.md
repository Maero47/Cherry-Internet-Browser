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

## Future Phases ⏳ PENDING

### Developer Tools
- [ ] WebKit Inspector integration
- [ ] Console access
- [ ] Network panel

### Additional Features
- [ ] Reading mode
- [ ] Screenshots (visible area, full page)
- [ ] Print/PDF
- [ ] Picture-in-Picture
- [ ] QR code generation
- [ ] Extensions/plugin system
- [ ] Touch ID for password access

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
