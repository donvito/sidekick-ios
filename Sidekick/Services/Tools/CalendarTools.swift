import Foundation
import EventKit

enum EventStoreProvider {
    static let store = EKEventStore()

    static func requestCalendarAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return }
        let granted = try await store.requestFullAccessToEvents()
        if !granted { throw ToolError("Calendar access was not granted. Enable it in Settings > Sidekick.") }
    }

    static func requestReminderAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return }
        let granted = try await store.requestFullAccessToReminders()
        if !granted { throw ToolError("Reminders access was not granted. Enable it in Settings > Sidekick.") }
    }

    static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        if let d = isoParser.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func describe(_ event: EKEvent) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = event.isAllDay ? .none : .short
        var line = "- \(event.title ?? "(untitled)"): \(f.string(from: event.startDate))"
        if !event.isAllDay { line += " → \(f.string(from: event.endDate))" }
        if let loc = event.location, !loc.isEmpty { line += " @ \(loc)" }
        return line
    }
}

struct ListCalendarEventsTool: AgentTool {
    let name = "list_calendar_events"
    let description = "List the user's calendar events between two dates. Use to check availability, plan the day, or find free slots. Dates are ISO 8601 (e.g. 2026-03-01T09:00:00+08:00)."
    let parameters = JSONSchema.object([
        "start": JSONSchema.string("Start of range, ISO 8601. Defaults to now."),
        "end": JSONSchema.string("End of range, ISO 8601. Defaults to 7 days after start."),
    ])

    func summary(for args: JSONValue) -> String { "Checking your calendar" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        try await EventStoreProvider.requestCalendarAccess()
        let start = args["start"]?.stringValue.flatMap(EventStoreProvider.parseDate) ?? .now
        let end = args["end"]?.stringValue.flatMap(EventStoreProvider.parseDate) ?? start.addingTimeInterval(7 * 86_400)
        let store = EventStoreProvider.store
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if events.isEmpty { return "No events between \(start.formatted()) and \(end.formatted())." }
        return events.prefix(60).map(EventStoreProvider.describe).joined(separator: "\n")
    }
}

struct CreateCalendarEventTool: AgentTool {
    let name = "create_calendar_event"
    let description = "Create an event on the user's default calendar. Times are ISO 8601 in the user's timezone."
    let parameters = JSONSchema.object([
        "title": JSONSchema.string("Event title"),
        "start": JSONSchema.string("Start time, ISO 8601"),
        "end": JSONSchema.string("End time, ISO 8601. Defaults to 1 hour after start."),
        "location": JSONSchema.string("Optional location"),
        "notes": JSONSchema.string("Optional notes/agenda"),
        "all_day": JSONSchema.boolean("Whether this is an all-day event"),
    ], required: ["title", "start"])
    let requiresApproval = true

    func summary(for args: JSONValue) -> String {
        let when = args["start"]?.stringValue.flatMap(EventStoreProvider.parseDate)?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return "Add “\(args["title"]?.stringValue ?? "event")” to your calendar \(when)"
    }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        try await EventStoreProvider.requestCalendarAccess()
        guard let title = args["title"]?.stringValue,
              let start = args["start"]?.stringValue.flatMap(EventStoreProvider.parseDate) else {
            throw ToolError("title and a valid ISO 8601 start are required")
        }
        let store = EventStoreProvider.store
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = args["end"]?.stringValue.flatMap(EventStoreProvider.parseDate) ?? start.addingTimeInterval(3600)
        event.isAllDay = args["all_day"]?.boolValue ?? false
        event.location = args["location"]?.stringValue
        event.notes = args["notes"]?.stringValue
        guard let calendar = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications }) else {
            throw ToolError("No writable calendar found on this device.")
        }
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return "Created event: \(EventStoreProvider.describe(event))"
    }
}

struct CreateReminderTool: AgentTool {
    let name = "create_reminder"
    let description = "Create a reminder (to-do) in the Reminders app, optionally with a due date."
    let parameters = JSONSchema.object([
        "title": JSONSchema.string("What to remind about"),
        "due": JSONSchema.string("Optional due date/time, ISO 8601"),
        "notes": JSONSchema.string("Optional notes"),
    ], required: ["title"])
    let requiresApproval = true

    func summary(for args: JSONValue) -> String { "Create reminder “\(args["title"]?.stringValue ?? "")”" }

    func run(args: JSONValue, context: ToolContext) async throws -> String {
        try await EventStoreProvider.requestReminderAccess()
        guard let title = args["title"]?.stringValue else { throw ToolError("title is required") }
        let store = EventStoreProvider.store
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = args["notes"]?.stringValue
        if let due = args["due"]?.stringValue.flatMap(EventStoreProvider.parseDate) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        guard let calendar = store.defaultCalendarForNewReminders() ?? store.calendars(for: .reminder).first else {
            throw ToolError("No reminders list found on this device.")
        }
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
        return "Created reminder “\(title)”" + (reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { " due \($0.formatted())" } ?? "")
    }
}
