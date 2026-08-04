//
//  MCPToolRegistryTests.swift
//  Internet BrowserTests
//
//  The tool declarations are the entire interface an external model sees, so
//  they are worth pinning: a schema that silently loses `additionalProperties`
//  or a description that gets truncated to a placeholder degrades every call
//  the model makes, and nothing else in the system would notice.
//

import XCTest
import MCP
@testable import Cherry

final class MCPToolRegistryTests: XCTestCase {

    func testExposesExactlyTheFiveDeclaredTools() {
        XCTAssertEqual(
            MCPToolRegistry.tools.map(\.name),
            ["list_tabs", "read_page", "search_history", "search_bookmarks", "open_tab"]
        )
    }

    func testToolNamesAreUnique() {
        let names = MCPToolRegistry.tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testLookupByName() {
        XCTAssertEqual(MCPToolRegistry.tool(named: "read_page")?.name, "read_page")
        XCTAssertNil(MCPToolRegistry.tool(named: "delete_history"))
    }

    /// Each description has to carry three things — what it does, when to use
    /// it, and what it will not do. A one-liner cannot; the length floor is a
    /// crude but effective guard against one creeping back in.
    func testEveryToolHasASubstantialDescription() {
        for tool in MCPToolRegistry.tools {
            let description = tool.description ?? ""
            XCTAssertGreaterThan(
                description.count, 200,
                "\(tool.name) has a \(description.count)-character description"
            )
        }
    }

    func testEverySchemaIsAClosedObject() {
        for tool in MCPToolRegistry.tools {
            guard case .object(let schema) = tool.inputSchema else {
                return XCTFail("\(tool.name) input schema is not an object")
            }
            XCTAssertEqual(schema["type"]?.stringValue, "object", "\(tool.name)")
            XCTAssertEqual(
                schema["additionalProperties"]?.boolValue, false,
                "\(tool.name) accepts unknown properties"
            )
            guard case .object(let properties)? = schema["properties"] else {
                return XCTFail("\(tool.name) has no properties object")
            }
            for (name, property) in properties {
                guard case .object(let field) = property else {
                    return XCTFail("\(tool.name).\(name) is not an object")
                }
                XCTAssertNotNil(field["type"]?.stringValue, "\(tool.name).\(name) has no type")
            }
        }
    }

    /// Anything named in `required` must actually exist in `properties`, or the
    /// client rejects every call before it reaches Cherry.
    func testRequiredFieldsExistInProperties() {
        for tool in MCPToolRegistry.tools {
            guard case .object(let schema) = tool.inputSchema,
                  case .array(let required)? = schema["required"]
            else {
                continue
            }
            guard case .object(let properties)? = schema["properties"] else {
                return XCTFail("\(tool.name) declares required fields but has no properties")
            }
            for entry in required {
                let name = entry.stringValue ?? ""
                XCTAssertNotNil(properties[name], "\(tool.name) requires undeclared field \(name)")
            }
        }
    }

    /// Every tool that returns data budgets its body to 40,000 characters, so every
    /// one of them needs the raised ceiling — without it Claude Code spills an
    /// over-large result to disk and hands the model a file reference instead.
    ///
    /// This used to be `read_page` alone, which was also the only tool whose output
    /// size was ever reasoned about. `list_tabs` could emit ~210,000 characters at
    /// 300 tabs and said nothing about it.
    func testEveryDataReturningToolRaisesItsResultSizeCeiling() {
        for name in ["list_tabs", "read_page", "search_history", "search_bookmarks"] {
            let tool = MCPToolRegistry.tool(named: name)
            XCTAssertEqual(
                tool?._meta?["anthropic/maxResultSizeChars"]?.intValue, 60_000,
                "\(name) does not raise its result-size ceiling"
            )
        }
    }

    /// The declared ceiling has to leave room above the body budget, or the
    /// declaration is decorative.
    func testTheDeclaredCeilingLeavesRoomAboveTheBodyBudget() {
        XCTAssertGreaterThan(MCPToolRegistry.maxResultSizeChars, MCPResultCaps.payloadChars)
    }

    func testOnlyOpenTabIsWritable() {
        for tool in MCPToolRegistry.tools where tool.name != "open_tab" {
            XCTAssertEqual(tool.annotations.readOnlyHint, true, "\(tool.name) is not marked read-only")
        }
        let openTab = MCPToolRegistry.tool(named: "open_tab")
        XCTAssertEqual(openTab?.annotations.readOnlyHint, false)
        XCTAssertEqual(openTab?.annotations.destructiveHint, false)
        XCTAssertEqual(openTab?.annotations.idempotentHint, false)
        XCTAssertEqual(openTab?.annotations.openWorldHint, true)
    }

    /// The tool list crosses the wire as JSON on every `tools/list`. If it
    /// cannot encode, the client sees an empty server.
    func testToolListEncodesToJSON() throws {
        let encoded = try JSONEncoder().encode(ListTools.Result(tools: MCPToolRegistry.tools))
        let decoded = try JSONDecoder().decode(ListTools.Result.self, from: encoded)
        XCTAssertEqual(decoded.tools.map(\.name), MCPToolRegistry.tools.map(\.name))
    }
}
