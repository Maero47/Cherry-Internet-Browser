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

## Phase 4: Enhanced Tab Management ⏳ PENDING

### Planned Features
- [ ] Tab groups with colors
- [ ] Pinned tabs
- [ ] Tab sleeping (memory management)
- [ ] Tab search (Cmd+Shift+A)
- [ ] Vertical tab bar option
- [ ] Tab preview on hover
- [ ] Drag-and-drop reordering

---

## Phase 5: Settings & Privacy ⏳ PENDING

### Planned Features
- [ ] Settings UI with sidebar navigation
- [ ] Private browsing mode
- [ ] Cookie management
- [ ] Site permissions (camera, mic, location)
- [ ] HTTPS-only mode option
- [ ] Clear browsing data
- [ ] Search engine selection
- [ ] Custom search engines

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
