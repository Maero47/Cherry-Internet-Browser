//
//  MCPToolRegistry.swift
//  Cherry Browser
//
//  The five tools Cherry exposes over MCP, as pure data.
//
//  The `description` strings are the entire interface an external model sees —
//  they are what decides whether a tool gets called correctly, called wrongly,
//  or not at all. Treat them as production copy, not comments: each one says
//  what the tool does, when to reach for it, and — the part models actually
//  need — what it will NOT do, so the model stops guessing and picks another
//  tool instead of retrying this one.
//
//  Nothing here touches an app type. That is deliberate: the registry is
//  `nonisolated` so the per-request `MCP.Server` factory can read it from the
//  SDK's executor without a hop, and so it can be unit-tested as plain data.
//

import Foundation
import MCP

nonisolated enum MCPToolRegistry {

    /// Every tool Cherry advertises, in the order `tools/list` returns them.
    static let tools: [Tool] = [
        listTabs,
        readPage,
        searchHistory,
        searchBookmarks,
        openTab,
    ]

    /// Look a tool up by the name a `tools/call` request carried.
    static func tool(named name: String) -> Tool? {
        tools.first { $0.name == name }
    }

    /// Read-only tools stay inside Cherry's own state, so the world they touch
    /// is closed. `destructiveHint`/`idempotentHint` are left unset because the
    /// spec defines them as meaningful only when `readOnlyHint` is false.
    private static let readOnly = Tool.Annotations(
        readOnlyHint: true,
        openWorldHint: false
    )

    // MARK: - 1. list_tabs

    static let listTabs = Tool(
        name: "list_tabs",
        description: """
            List the tabs currently open in the user's Cherry browser, across every non-private window. \
            Returns each tab's id, title, URL, which window it belongs to, and whether it is the selected \
            tab, pinned, sleeping, loading, or showing an internal `cherry://` page.

            Use this to find out what the user is working on, or to get a `tab_id` to pass to `read_page`.

            Do not use this to read page content — it returns titles and URLs only, never page text. Do not \
            assume the list is stable: the user is browsing, so tab ids may disappear between calls. Private \
            and incognito windows are never included and their existence is not reported.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "window_id": [
                    "type": "string",
                    "description": "Optional. Restrict to one window, using an id returned by a previous list_tabs call.",
                ]
            ],
            "additionalProperties": false,
        ],
        annotations: readOnly
    )

    // MARK: - 2. read_page

    /// Claude Code persists an over-large tool result to disk and hands the
    /// model a file reference instead. `read_page` chunks at 40,000 characters,
    /// so raising the ceiling to 60,000 leaves the JSON envelope room to fit
    /// without tripping that.
    static let readPageMaxResultSizeChars = 60_000

    static let readPage = Tool(
        name: "read_page",
        description: """
            Extract the readable text of a page open in the user's Cherry browser. Pass a `tab_id` from \
            `list_tabs`, or omit it to read the tab the user is currently looking at.

            Use this when you need the actual content of something the user has on screen — an article they \
            are reading, docs they are looking at, a page they just asked about.

            This reads what is genuinely displayed. It will refuse, with a reason, when there is nothing on \
            screen to read: a sleeping tab, a Cherry settings/history/bookmarks page, the new-tab page, or a \
            PDF. It does not navigate, click, scroll, or run arbitrary JavaScript, and it cannot read a page \
            that is not already open — use `open_tab` first if you need a page loaded, then read it.

            Long pages are returned in chunks. Check `has_more` and call again with `offset` set to \
            `next_offset` if you need the rest; do not re-read from the start.
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "tab_id": [
                    "type": "string",
                    "description": "Tab to read. Omit for the tab the user is currently focused on.",
                ],
                "offset": [
                    "type": "integer",
                    "minimum": 0,
                    "default": 0,
                    "description": "Character offset into the extracted text. Use next_offset from a previous call.",
                ],
            ],
            "additionalProperties": false,
        ],
        annotations: readOnly,
        _meta: Metadata(additionalFields: [
            "anthropic/maxResultSizeChars": .int(readPageMaxResultSizeChars)
        ])
    )

    // MARK: - 3. search_history

    static let searchHistory = Tool(
        name: "search_history",
        description: """
            Search the user's Cherry browsing history by title and URL substring. Returns the most recently \
            visited matches first, with visit counts.

            Use this to answer "what was that page I looked at", to find a URL the user half-remembers, or \
            to check whether they have already read something.

            This is a plain case-insensitive substring match over title and URL — it is not a semantic \
            search and does not search page content. It cannot see anything visited in a private window, \
            because Cherry does not record those. Treat what it returns as sensitive: it is a record of what \
            the user personally read.
            """,
        inputSchema: [
            "type": "object",
            "required": ["query"],
            "properties": [
                "query": [
                    "type": "string",
                    "minLength": 1,
                    "description": "Substring to match against page titles and URLs.",
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100,
                    "default": 25,
                ],
                "since_days": [
                    "type": "integer",
                    "minimum": 1,
                    "description": "Optional. Only entries visited within this many days.",
                ],
            ],
            "additionalProperties": false,
        ],
        annotations: readOnly
    )

    // MARK: - 4. search_bookmarks

    static let searchBookmarks = Tool(
        name: "search_bookmarks",
        description: """
            Search the user's saved bookmarks in Cherry by title and URL substring. Returns the folder each \
            bookmark is filed under.

            Use this to find a page the user deliberately kept, or to see how they have organised a topic.

            Bookmarks are what the user chose to save; `search_history` is everything they happened to \
            visit. If you want "have they seen this", use history. Pass an empty-ish query only if you \
            genuinely want a listing — this returns saved pages, not page content.
            """,
        inputSchema: [
            "type": "object",
            "required": ["query"],
            "properties": [
                "query": [
                    "type": "string",
                    "description": #"Substring to match against bookmark titles and URLs. Pass "" to list all bookmarks (still subject to limit)."#,
                ],
                "folder": [
                    "type": "string",
                    "description": "Optional. Restrict to one folder name.",
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 200,
                    "default": 50,
                ],
            ],
            "additionalProperties": false,
        ],
        annotations: readOnly
    )

    // MARK: - 5. open_tab

    static let openTab = Tool(
        name: "open_tab",
        description: """
            Open a URL in a new tab in the user's Cherry browser. Returns the new tab's id, which you can \
            pass to `read_page` once the page has loaded.

            Use this when the user asks you to open something, or when you need to read a page that is not \
            already open.

            This changes what is on the user's screen, so do not call it speculatively or in a loop — one \
            deliberate tab at a time. It only opens `http` and `https` URLs. It cannot click, type, submit \
            forms, or interact with the page in any way after opening it. The page will not be readable \
            immediately; expect `read_page` to report `loading` on the first attempt.
            """,
        inputSchema: [
            "type": "object",
            "required": ["url"],
            "properties": [
                "url": [
                    "type": "string",
                    "format": "uri",
                    "description": "An http:// or https:// URL.",
                ],
                "window_id": [
                    "type": "string",
                    "description": "Optional. Open in this window; defaults to the frontmost non-private window.",
                ],
                "activate": [
                    "type": "boolean",
                    "default": false,
                    "description": "Bring the new tab to the foreground. Defaults to false so the user's current tab is not stolen.",
                ],
            ],
            "additionalProperties": false,
        ],
        annotations: Tool.Annotations(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: true
        )
    )
}
