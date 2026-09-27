import Foundation
import LiteRTLM

/// Routes tool calls made by the on-device model (executed inside LiteRT-LM's conversation loop) back to
/// the agent runner, which owns approval, persistence and the actual Sidekick tool implementation.
@MainActor
final class LocalToolDispatcher {
    static let shared = LocalToolDispatcher()
    typealias Handler = @MainActor (_ name: String, _ argumentsJSON: String) async -> String

    private var handler: Handler?

    private init() {}

    func begin(_ handler: @escaping Handler) { self.handler = handler }
    func end() { handler = nil }

    func dispatch(name: String, arguments: [String: Any]) async -> String {
        guard let handler else { return "Error: no task is listening for tool calls." }
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
        return await handler(name, String(decoding: data, as: UTF8.self))
    }
}

/// LiteRT-LM `Tool` mirrors of the offline-capable Sidekick tools. LiteRT-LM derives each schema from the
/// `@ToolParam` properties via reflection (camelCase → snake_case), so names here must match `ToolRegistry`.
enum LocalTools {
    static func all(for tools: [AgentTool]) -> [Tool] {
        let names = Set(tools.map(\.name))
        let mirrors: [Tool] = [
            GetCurrentDatetime(), ListCalendarEvents(), CreateCalendarEvent(), CreateReminder(),
            CreateNote(), CreateDocument(), DraftEmail(), GetHealthSummary(), Remember(),
        ]
        return mirrors.filter { names.contains(type(of: $0).name) }
    }

    static func send(_ name: String, _ args: [String: Any?]) async -> String {
        let compact = args.compactMapValues { $0 }
        return await LocalToolDispatcher.shared.dispatch(name: name, arguments: compact)
    }

    struct GetCurrentDatetime: Tool {
        static let name = "get_current_datetime"
        static let description = "Get the current date, time and timezone."
        init() {}
        func run() async throws -> Any { await LocalTools.send(Self.name, [:]) }
    }

    struct ListCalendarEvents: Tool {
        static let name = "list_calendar_events"
        static let description = "List the user's calendar events between two dates to check availability or plan the day. Dates are ISO 8601 like 2026-03-01T09:00:00+08:00."
        @ToolParam(description: "Start of range, ISO 8601. Defaults to now.")
        var start: String?
        @ToolParam(description: "End of range, ISO 8601. Defaults to 7 days after start.")
        var end: String?
        init() {}
        func run() async throws -> Any { await LocalTools.send(Self.name, ["start": start, "end": end]) }
    }

    struct CreateCalendarEvent: Tool {
        static let name = "create_calendar_event"
        static let description = "Create an event on the user's calendar. Times are ISO 8601 in the user's timezone, e.g. 2026-03-01T15:00:00+08:00."
        @ToolParam(description: "Event title")
        var title: String
        @ToolParam(description: "Start time, ISO 8601")
        var start: String
        @ToolParam(description: "End time, ISO 8601. Defaults to 1 hour after start.")
        var end: String?
        @ToolParam(description: "Optional location")
        var location: String?
        @ToolParam(description: "Optional notes or agenda")
        var notes: String?
        @ToolParam(description: "Whether this is an all-day event")
        var allDay: Bool = false
        init() {}
        func run() async throws -> Any {
            await LocalTools.send(Self.name, ["title": title, "start": start, "end": end, "location": location, "notes": notes, "all_day": allDay])
        }
    }

    struct CreateReminder: Tool {
        static let name = "create_reminder"
        static let description = "Create a to-do in the Reminders app, optionally with a due date."
        @ToolParam(description: "What to remind about")
        var title: String
        @ToolParam(description: "Optional due date/time, ISO 8601")
        var due: String?
        @ToolParam(description: "Optional notes")
        var notes: String?
        init() {}
        func run() async throws -> Any { await LocalTools.send(Self.name, ["title": title, "due": due, "notes": notes]) }
    }

    struct CreateNote: Tool {
        static let name = "create_note"
        static let description = "Save a note (meeting notes, ideas, lists, journal entries) to the user's Library; they can send it to Apple Notes with one tap. Write the full body in markdown."
        @ToolParam(description: "Short note title")
        var title: String
        @ToolParam(description: "Full note content, markdown allowed")
        var body: String
        init() {}
        func run() async throws -> Any { await LocalTools.send(Self.name, ["title": title, "body": body]) }
    }

    struct CreateDocument: Tool {
        static let name = "create_document"
        static let description = "Create a file (report, plan, list, csv) and save it to the user's Library. Write the complete content."
        @ToolParam(description: "Short human title")
        var title: String
        @ToolParam(description: "File format: markdown, pdf, text or csv")
        var format: String = "markdown"
        @ToolParam(description: "Complete file content")
        var content: String
        init() {}
        func run() async throws -> Any { await LocalTools.send(Self.name, ["title": title, "format": format, "content": content]) }
    }

    struct DraftEmail: Tool {
        static let name = "draft_email"
        static let description = "Draft an email the user can open in Mail."
        @ToolParam(description: "Recipient email address(es), comma separated. Empty if unknown.")
        var to: String = ""
        @ToolParam(description: "Email subject")
        var subject: String
        @ToolParam(description: "Full plain-text email body")
        var body: String
        init() {}
        func run() async throws -> Any { await LocalTools.send(Self.name, ["to": to, "subject": subject, "body": body]) }
    }

    struct GetHealthSummary: Tool {
        static let name = "get_health_summary"
        static let description = "Read a summary of the user's recent Apple Health data (steps, sleep, heart rate, workouts)."
        @ToolParam(description: "Number of past days to include (1-30). Default 7.")
        var days: Int = 7
        init() {}
        func run() async throws -> Any { await LocalTools.send(Self.name, ["days": days]) }
    }

    struct Remember: Tool {
        static let name = "remember"
        static let description = "Save a durable fact or preference the user shared, for future tasks."
        @ToolParam(description: "One concise sentence to remember")
        var fact: String
        init() {}
        func run() async throws -> Any { await LocalTools.send(Self.name, ["fact": fact]) }
    }
}
