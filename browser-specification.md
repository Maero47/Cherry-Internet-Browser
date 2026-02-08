# Modern macOS Web Browser - Complete Specification

Create a complete, production-ready web browser for macOS with the following specifications:

## CORE ARCHITECTURE

### Browser Engine
- Use WKWebView as the rendering engine with full WebKit integration
- Implement custom WKNavigationDelegate and WKUIDelegate for complete control
- Support for modern web standards: HTML5, CSS3, ES2022+, WebAssembly
- Hardware-accelerated rendering and GPU compositing
- Multi-process architecture with separate processes for tabs (sandboxing)

### Application Structure
- Swift 5.9+ with modern async/await patterns
- SwiftUI for UI (macOS 13+ target)
- Combine framework for reactive programming
- Core Data for persistent storage (LOCAL ONLY - no cloud sync)
- All data stored on local machine

## DATA STORAGE PHILOSOPHY

### Local-First Architecture
- **No user accounts or login system**
- **No cloud sync** - all data stays on the user's Mac
- **Complete privacy** - no data leaves the device
- All storage uses local filesystem and macOS frameworks
- Optional export/import for manual backup

### Storage Locations
- **Core Data**: Bookmarks, history, settings (~/Library/Application Support/MyBrowser/)
- **Keychain**: Passwords and sensitive data (macOS Keychain, local only)
- **UserDefaults**: Simple preferences and UI state
- **File System**: Downloads, cache, extension data
- **SQLite**: Extension storage, custom databases

## USER INTERFACE DESIGN

### Visual Design (Modern, Chrome-inspired but evolved)

#### Color Scheme
- **Light mode**: Clean whites (#FFFFFF), subtle grays (#F5F5F5), accent blue (#0A84FF)
- **Dark mode**: True blacks (#000000), dark grays (#1C1C1E), vibrant accent (#0A84FF)
- System appearance auto-detection
- Smooth transitions between modes

#### Layout
- Frameless window with custom title bar
- Minimal chrome, maximum content area
- Unified address/search bar (omnibox) with rounded corners
- Tab bar with smooth animations, tab preview on hover
- Collapsible sidebar for bookmarks/history/downloads
- Bottom status bar (hideable) for loading indicators

#### Typography
- SF Pro Display for UI elements
- SF Mono for developer tools
- Dynamic type support for accessibility

### Tab System

#### Tab Management
- Unlimited tabs with intelligent memory management
- Tab groups with custom names and colors
- Pinned tabs (smaller, favicon only)
- Tab sleeping for inactive tabs (memory optimization)
- Drag-and-drop reordering within and between windows
- Vertical tab bar option (collapsible sidebar)
- Tab preview thumbnails on hover
- Recently closed tabs recovery (with timestamps) - STORED LOCALLY
- Tab search functionality (Cmd+Shift+A)

#### Tab Features
- Duplicate tab
- Mute/unmute individual tabs
- Pin/unpin tabs
- Move tab to new window
- Close tabs to the right
- Close other tabs
- Reopen closed tab (Cmd+Shift+T)

### Omnibox (Unified Address/Search Bar)

#### Functionality
- Smart URL detection vs. search query
- Real-time suggestions from LOCAL sources:
  * Browser history (weighted by frequency and recency) - LOCAL ONLY
  * Bookmarks - LOCAL ONLY
  * Open tabs
  * Search suggestions from default search engine (only external call)
  * Calculator for mathematical expressions
  * Unit conversions (currency, measurements)
- Keyboard shortcuts for different suggestion types
- Rich previews for bookmarks/history items
- Security indicators (HTTPS lock, certificate info)
- Page actions (bookmark, share, translate)

#### Search Engine Integration
- Default: Google (customizable)
- Support for custom search engines with keyword shortcuts
- DuckDuckGo, Bing, Ecosia, Brave Search built-in
- Custom search engine addition via OpenSearch

### Navigation Controls

#### Standard Controls
- Back/Forward buttons with long-press history menu
- Reload/Stop button (morphs based on state)
- Home button (optional, user can toggle)
- Download manager button with progress indicator
- Extensions button
- Settings button (no profile/account button)

#### Gestures
- Two-finger swipe for back/forward
- Pinch to zoom
- Three-finger swipe for tab switching
- Smart zoom (double-tap with two fingers)

## FEATURES

### Bookmarks System (LOCAL STORAGE)

#### Organization
- Bookmark bar (toggleable)
- Bookmark manager with folder hierarchy
- Tags for bookmarks
- Automatic favicon fetching and caching (stored locally)
- Bookmark search with fuzzy matching
- Import/export (HTML, Chrome, Safari, Firefox formats) - MANUAL BACKUP OPTION
- ALL DATA STORED IN LOCAL CORE DATA DATABASE

#### Smart Bookmarks
- Frequently visited bookmarks auto-suggest
- Bookmark analytics (visit count, last accessed)
- Duplicate detection and merging
- Broken link detection and notifications

#### Backup Options
- Export bookmarks to HTML/JSON
- Import from other browsers
- Manual backup reminder (optional)

### History (LOCAL STORAGE ONLY)

#### Storage
- Comprehensive browsing history with timestamps - STORED LOCALLY
- Full-text search across page titles and URLs
- Filter by date range, domain, visit count
- History graph visualization (daily/weekly/monthly)
- Privacy controls (clear history, exclude domains)
- Automatic history cleanup (configurable retention period)
- ALL STORED IN LOCAL CORE DATA

#### Advanced Features
- NO SYNC - history stays on this device only
- Session restore after crash (from local storage)
- History export (CSV, JSON) for manual backup
- Configurable retention (1 week, 1 month, 3 months, 1 year, forever)

### Downloads Manager (LOCAL)

#### Interface
- Dropdown panel from toolbar button
- Full downloads page (chrome://downloads equivalent)
- Progress indicators with speed and ETA
- Pause/resume/cancel functionality
- Open file location
- Clear completed downloads

#### Features
- Automatic file type detection
- Dangerous file warnings
- Download location customization (global and per-file)
- Download history with search - STORED LOCALLY
- Parallel downloads support
- Resume interrupted downloads
- Integration with macOS Finder (Quick Look support)

### Privacy & Security

#### Privacy Modes
- Private browsing mode (separate window, no history/cookies saved)
- Tracker blocking (built-in lists + customizable)
- Cookie management (allow, block, clear) - STORED LOCALLY
- Site-specific permissions (camera, mic, location, notifications) - LOCAL
- HTTPS-only mode (upgrade all connections)
- DNS-over-HTTPS (DoH) support

#### Security Features
- Certificate pinning
- Mixed content blocking
- XSS protection
- Safe browsing (Google Safe Browsing API integration - only security check that's external)
- Password breach alerts (Have I Been Pwned API - optional, privacy-preserving)
- Automatic HTTPS upgrades
- Security indicator in omnibox (lock icon with details)

#### Privacy Philosophy
- NO telemetry or analytics sent to servers
- NO crash reports unless user explicitly enables
- NO usage tracking
- All data processing happens locally

### Password Manager (LOCAL KEYCHAIN)

#### Core Features
- Encrypted password storage (macOS Keychain - LOCAL ONLY)
- Auto-fill for login forms
- Password generation (customizable length/complexity)
- Password strength indicator
- Duplicate password detection
- Compromised password alerts (Have I Been Pwned API - OPTIONAL, user can disable)
- Two-factor authentication (TOTP) support - stored locally

#### UI
- Password manager interface (list view with search)
- Import/export (CSV, 1Password, LastPass formats) - for manual backup
- NO cloud sync - passwords stay in local Keychain
- Biometric authentication (Touch ID/Face ID) for access
- Master password option for additional security

#### Backup
- Export passwords to encrypted file
- Import from other password managers
- Warning about keeping backups secure

### Autofill (LOCAL STORAGE)

#### Types
- Addresses (shipping, billing)
- Credit cards (with CVV masking)
- Contact information
- Custom form data

#### Features
- Smart form detection
- Multi-step form support
- Profile management (multiple profiles)
- Secure storage with encryption - LOCAL ONLY
- Stored in local Core Data with encryption

### Developer Tools

#### Inspector
- Elements panel (DOM tree, live editing)
- Console (JavaScript execution, logging)
- Sources (debugger, breakpoints, code navigation)
- Network panel (request/response inspection, timing, throttling)
- Performance profiler (CPU, memory, rendering)
- Memory profiler (heap snapshots, allocation tracking)
- Application panel (storage, caching, service workers)
- Security panel (certificate inspection, mixed content)

#### Additional Tools
- Responsive design mode (device emulation)
- Color picker and contrast analyzer
- CSS grid/flexbox visualizer
- Accessibility inspector
- 3D view of DOM layers
- Lighthouse integration (performance auditing) - runs locally

### Extensions System (LOCAL)

#### Architecture
- Safari Web Extensions API compatibility
- Manifest V3 support
- Background scripts (service workers)
- Content scripts injection
- Browser action/page action APIs
- Message passing between components
- Native messaging for app integration

#### Store & Management
- Load extensions from local files (.safariextz or custom format)
- Extension manager UI (enable/disable, permissions, updates)
- Developer mode for unpacked extensions
- Extension security sandboxing
- Extension data stored locally (no cloud sync)
- Manual extension installation (drag-and-drop or file picker)

### Settings/Preferences (LOCAL STORAGE)

#### Categories
- **General**: Startup behavior, default page, download location
- **Appearance**: Themes, tab bar position, sidebar
- **Search**: Default engine, suggestions, omnibox behavior
- **Privacy**: Tracking, cookies, site data, permissions
- **Security**: HTTPS, safe browsing, certificates
- **Passwords**: Manager settings, auto-fill preferences
- **Autofill**: Addresses, payment methods
- **Languages**: Preferred languages, translation settings
- **Downloads**: Default location, ask where to save
- **Extensions**: Manage extensions
- **Data Management**: Clear browsing data, export/import options
- **Advanced**: Hardware acceleration, experimental features
- **Developer**: Remote debugging, extension development

#### UI
- Modern settings page with search
- Side navigation for categories
- Reset to defaults option
- Import settings from other browsers
- Export/import settings for backup

#### Data Management Section
- Clear browsing data (history, cookies, cache, passwords)
- Export all data (bookmarks, history, passwords) for backup
- Import data from other browsers
- Storage usage breakdown
- No sync options (emphasize local-only storage)

### Performance Optimizations

#### Memory Management
- Tab discarding for inactive tabs (configurable threshold)
- Lazy loading for background tabs
- Aggressive garbage collection
- Image lazy loading for web content

#### Rendering
- Hardware acceleration (Metal API)
- Compositor thread optimization
- Predictive prefetching
- Smart caching strategies (all local)

#### Networking
- HTTP/3 and QUIC support
- Connection pooling
- DNS prefetching
- Preconnect to likely targets

### Accessibility

#### Features
- Full VoiceOver support
- High contrast mode
- Text scaling
- Keyboard navigation throughout
- Reduced motion support
- Color blindness modes
- Screen reader optimized UI

### NO SYNC OR ACCOUNTS

#### Explicitly Remove
- No user accounts
- No login/signup flow
- No cloud sync of any kind
- No profile switching across devices
- No "Sign in to sync" prompts

#### Backup Philosophy
- All backup is manual and user-initiated
- Export features for bookmarks, history, passwords
- Import features from other browsers
- Time Machine backup support (all data in standard locations)

### Additional Features

#### Reading Mode
- Distraction-free reading
- Customizable fonts and spacing
- Text-to-speech integration (macOS native)
- Save for offline reading (stored locally)

#### Translation
- Built-in page translation (Google Translate API or Apple's Translation framework)
- Auto-detect language
- Translation history (stored locally)

#### Media Controls
- Picture-in-Picture for videos
- Media keys support (play/pause)
- Now Playing integration with macOS
- Audio ducking for multiple tabs

#### Screenshots
- Capture visible area
- Capture full page (scrolling)
- Selection tool
- Annotation tools
- Direct save or copy to clipboard

#### Print
- Native print dialog
- Save as PDF
- Print preview with page setup
- Margin and scaling controls

#### QR Code Generation
- Generate QR for current page
- Share via QR code

#### Window Management
- Multiple windows support
- Session management (save/restore window states) - STORED LOCALLY
- Window snapping (macOS 15+)
- Full-screen mode

## TECHNICAL REQUIREMENTS

### Code Quality

#### Architecture Patterns
- MVVM for UI components
- Repository pattern for data layer (local repositories only)
- Coordinator pattern for navigation
- Dependency injection throughout

#### Standards
- SwiftLint integration with strict rules
- Unit tests (XCTest) with >80% coverage
- UI tests for critical flows
- Documentation comments for all public APIs
- Error handling with custom error types

### Performance Metrics

#### Targets
- App launch: <500ms cold start
- Tab opening: <100ms
- Page load: Optimize for Core Web Vitals
- Memory per tab: <100MB average
- 60 FPS scrolling and animations

### Data Storage (LOCAL ONLY)

#### Technologies
- Core Data for structured data (bookmarks, history, settings) - LOCAL
- UserDefaults for simple preferences - LOCAL
- Keychain for sensitive data (passwords) - LOCAL macOS Keychain
- File system for downloads and cache - LOCAL
- SQLite for extension storage - LOCAL

#### Storage Locations
- `~/Library/Application Support/MyBrowser/` - Core Data, caches
- `~/Library/Preferences/com.mycompany.mybrowser.plist` - UserDefaults
- Keychain - Passwords (macOS secure storage)
- `~/Downloads/` or custom - Downloads

#### Backup Strategy
- All data in standard macOS locations (Time Machine compatible)
- Export functionality for manual backups
- Import from other browsers

### Networking

#### Implementation
- URLSession with custom configurations
- Certificate pinning for critical domains
- Request/response interceptors
- Offline mode handling
- Cache management (NSCache + custom disk cache) - ALL LOCAL

### Build Configuration

#### Requirements
- Minimum macOS version: 13.0 (Ventura)
- Swift 5.9+
- Xcode 15+
- Code signing and notarization ready
- Release and Debug configurations
- Proper entitlements (network, keychain access - local only)

## PROJECT STRUCTURE

```
MyBrowser/
├── App/
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   └── MyBrowserApp.swift
├── Core/
│   ├── Extensions/
│   ├── Utilities/
│   ├── Constants/
│   └── Protocols/
├── Features/
│   ├── Browser/
│   │   ├── Views/
│   │   ├── ViewModels/
│   │   └── Models/
│   ├── Tabs/
│   ├── Bookmarks/
│   ├── History/
│   ├── Downloads/
│   ├── Settings/
│   ├── Extensions/
│   └── DevTools/
├── Data/
│   ├── Repositories/ (Local only)
│   ├── Models/
│   ├── CoreData/
│   ├── Keychain/
│   └── Network/
├── Resources/
│   ├── Assets.xcassets
│   ├── Localizations/
│   └── Fonts/
└── Tests/
    ├── UnitTests/
    └── UITests/
```

## DELIVERABLES

1. Complete Xcode project with all source files
2. Comprehensive README with setup instructions
3. Architecture documentation (emphasizing local-only storage)
4. User guide (markdown) - explain privacy-first, local-only approach
5. API documentation (generated with DocC)
6. Build scripts for release preparation
7. Test suite with examples
8. Sample extensions for demonstration
9. Data export/import utilities documentation

## ADDITIONAL NOTES

- Use modern Swift features (async/await, Actors, property wrappers)
- Follow Apple Human Interface Guidelines
- Implement proper error handling and user feedback
- NO analytics or telemetry
- NO crash reporting to servers (optionally save crash logs locally)
- Add keyboard shortcuts for power users (comprehensive list)
- Add Easter eggs or hidden features for delight
- Implement local crash logging (with user option to view/delete)
- Add onboarding flow emphasizing privacy and local storage
- Create beautiful empty states for all views
- Prominent messaging about privacy-first, local-only approach

## PRIVACY & LOCAL STORAGE EMPHASIS

Throughout the UI, make it clear that:
- "All your data stays on your Mac"
- "No account required"
- "Your privacy is protected - nothing leaves your device"
- Settings should have a "Privacy" section explaining the local-only approach
- First launch should explain the privacy benefits
- Export/import features should be prominent for manual backup

---

**The browser should feel fast, modern, secure, private, and delightful to use. It should respect user privacy by keeping ALL data local. Every interaction should be smooth and intuitive. The codebase should be maintainable, testable, and ready for future enhancements. The browser should be completely usable without any internet connection (except for browsing websites).**
