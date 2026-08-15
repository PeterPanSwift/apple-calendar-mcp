// calendar-bridge — a small EventKit CLI used by the Apple Calendar MCP server.
//
// Protocol: one JSON request object on stdin, one JSON response object on stdout.
//   request:  {"command": "...", ...args}
//   response: {"ok": true, "data": ...} | {"ok": false, "error": "...", "code": "..."}
//
// EventKit is used instead of AppleScript because it expands recurring events into
// real occurrences, which Calendar.app's scripting interface does not do.

import EventKit
import Foundation

// MARK: - JSON helpers

func fail(_ message: String, code: String = "error") -> Never {
    let payload: [String: Any] = ["ok": false, "error": message, "code": code]
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
        FileHandle.standardOutput.write(data)
    }
    exit(1)
}

func succeed(_ data: Any) -> Never {
    let payload: [String: Any] = ["ok": true, "data": data]
    guard let out = try? JSONSerialization.data(withJSONObject: payload) else {
        fail("failed to serialize response")
    }
    FileHandle.standardOutput.write(out)
    exit(0)
}

let isoOut: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f
}()

func iso(_ date: Date) -> String { isoOut.string(from: date) }

/// Accepts `2026-08-15T09:00:00Z`, `2026-08-15T09:00:00+08:00`, `2026-08-15T09:00`,
/// `2026-08-15 09:00`, and `2026-08-15` (midnight local).
func parseDate(_ raw: String) -> Date? {
    let s = raw.trimmingCharacters(in: .whitespaces)

    let withTZ = ISO8601DateFormatter()
    withTZ.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withTZ.date(from: s) { return d }
    withTZ.formatOptions = [.withInternetDateTime]
    if let d = withTZ.date(from: s) { return d }

    let patterns = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
    for pattern in patterns {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = pattern
        if let d = f.date(from: s) { return d }
    }
    return nil
}

// MARK: - Request

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let root = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
    fail("stdin was not a JSON object", code: "bad_request")
}
guard let command = root["command"] as? String else {
    fail("missing \"command\"", code: "bad_request")
}

func str(_ key: String) -> String? {
    guard let v = root[key] as? String, !v.isEmpty else { return nil }
    return v
}
func bool(_ key: String) -> Bool? { root[key] as? Bool }
func num(_ key: String) -> Double? { (root[key] as? NSNumber)?.doubleValue }
func strings(_ key: String) -> [String]? { root[key] as? [String] }

func requiredDate(_ key: String) -> Date {
    guard let raw = str(key) else { fail("missing \"\(key)\"", code: "bad_request") }
    guard let d = parseDate(raw) else { fail("could not parse \"\(key)\": \(raw)", code: "bad_request") }
    return d
}
func optionalDate(_ key: String) -> Date? {
    guard let raw = str(key) else { return nil }
    guard let d = parseDate(raw) else { fail("could not parse \"\(key)\": \(raw)", code: "bad_request") }
    return d
}

// MARK: - Store & access

let store = EKEventStore()

func requestAccess() {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    var accessError: Error?

    let handler: (Bool, Error?) -> Void = { ok, err in
        granted = ok
        accessError = err
        semaphore.signal()
    }

    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents(completion: handler)
    } else {
        store.requestAccess(to: .event, completion: handler)
    }

    // The completion runs on a background queue, so a plain wait is safe here.
    if semaphore.wait(timeout: .now() + 60) == .timedOut {
        fail("timed out waiting for calendar access", code: "permission_timeout")
    }
    if let accessError {
        fail("calendar access failed: \(accessError.localizedDescription)", code: "permission_denied")
    }
    if !granted {
        fail("calendar access was not granted. Enable it in System Settings > Privacy & Security > Calendars for the app running this server (e.g. Terminal or Claude).",
             code: "permission_denied")
    }
}

requestAccess()

// MARK: - Serialization

func serialize(calendar cal: EKCalendar) -> [String: Any] {
    var out: [String: Any] = [
        "id": cal.calendarIdentifier,
        "title": cal.title,
        "allowsModification": cal.allowsContentModifications,
        "isSubscribed": cal.isSubscribed,
        "source": cal.source?.title ?? "Unknown",
        "type": {
            switch cal.type {
            case .local: return "local"
            case .calDAV: return "caldav"
            case .exchange: return "exchange"
            case .subscription: return "subscription"
            case .birthday: return "birthday"
            @unknown default: return "unknown"
            }
        }() as String,
    ]
    if let color = cal.cgColor, let components = color.components, components.count >= 3 {
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        out["color"] = String(format: "#%02X%02X%02X", r, g, b)
    }
    return out
}

func availabilityName(_ a: EKEventAvailability) -> String {
    switch a {
    case .busy: return "busy"
    case .free: return "free"
    case .tentative: return "tentative"
    case .unavailable: return "unavailable"
    case .notSupported: return "notSupported"
    @unknown default: return "unknown"
    }
}

func statusName(_ s: EKEventStatus) -> String {
    switch s {
    case .none: return "none"
    case .confirmed: return "confirmed"
    case .tentative: return "tentative"
    case .canceled: return "canceled"
    @unknown default: return "unknown"
    }
}

func serialize(event ev: EKEvent, detailed: Bool = false) -> [String: Any] {
    var out: [String: Any] = [
        "id": ev.eventIdentifier ?? "",
        "title": ev.title ?? "(untitled)",
        "start": iso(ev.startDate),
        "end": iso(ev.endDate),
        "allDay": ev.isAllDay,
        "calendar": ev.calendar?.title ?? "",
        "calendarId": ev.calendar?.calendarIdentifier ?? "",
        "isRecurring": ev.hasRecurrenceRules,
        "availability": availabilityName(ev.availability),
        "editable": ev.calendar?.allowsContentModifications ?? false,
    ]
    if let location = ev.location, !location.isEmpty { out["location"] = location }
    if let url = ev.url { out["url"] = url.absoluteString }
    if ev.hasRecurrenceRules {
        // Identifies which occurrence this is; required to edit a single instance.
        out["occurrenceStart"] = iso(ev.occurrenceDate)
    }

    guard detailed else { return out }

    if let notes = ev.notes, !notes.isEmpty { out["notes"] = notes }
    out["status"] = statusName(ev.status)
    if let organizer = ev.organizer {
        out["organizer"] = organizer.name ?? organizer.url.absoluteString
    }
    if let attendees = ev.attendees, !attendees.isEmpty {
        out["attendees"] = attendees.map { a -> [String: Any] in
            var entry: [String: Any] = ["name": a.name ?? a.url.absoluteString]
            entry["email"] = a.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            entry["status"] = {
                switch a.participantStatus {
                case .accepted: return "accepted"
                case .declined: return "declined"
                case .tentative: return "tentative"
                case .pending: return "pending"
                case .delegated: return "delegated"
                case .completed: return "completed"
                case .inProcess: return "inProcess"
                case .unknown: return "unknown"
                @unknown default: return "unknown"
                }
            }() as String
            entry["isOrganizer"] = a.isCurrentUser && ev.organizer?.url == a.url
            return entry
        }
    }
    if let alarms = ev.alarms, !alarms.isEmpty {
        out["alarms"] = alarms.map { alarm -> [String: Any] in
            if let absolute = alarm.absoluteDate { return ["at": iso(absolute)] }
            return ["minutesBefore": Int((-alarm.relativeOffset / 60).rounded())]
        }
    }
    if let rules = ev.recurrenceRules, !rules.isEmpty {
        out["recurrence"] = rules.map { describe(rule: $0) }
    }
    if let created = ev.creationDate { out["created"] = iso(created) }
    if let modified = ev.lastModifiedDate { out["modified"] = iso(modified) }
    return out
}

func describe(rule: EKRecurrenceRule) -> [String: Any] {
    var out: [String: Any] = ["interval": rule.interval]
    out["frequency"] = {
        switch rule.frequency {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "unknown"
        }
    }() as String
    if let days = rule.daysOfTheWeek, !days.isEmpty {
        let names = ["", "SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        out["daysOfWeek"] = days.map { names[$0.dayOfTheWeek.rawValue] }
    }
    if let end = rule.recurrenceEnd {
        if let endDate = end.endDate { out["until"] = iso(endDate) }
        else if end.occurrenceCount > 0 { out["count"] = end.occurrenceCount }
    }
    return out
}

// MARK: - Lookup helpers

func calendars(fromIdsOrTitles values: [String]?) -> [EKCalendar]? {
    guard let values, !values.isEmpty else { return nil }
    let all = store.calendars(for: .event)
    var picked: [EKCalendar] = []
    for value in values {
        let match = all.first { $0.calendarIdentifier == value }
            ?? all.first { $0.title.caseInsensitiveCompare(value) == .orderedSame }
        guard let match else {
            fail("no calendar named or identified by \"\(value)\"", code: "not_found")
        }
        picked.append(match)
    }
    return picked
}

func resolveCalendar(_ value: String?) -> EKCalendar {
    if let value, let match = calendars(fromIdsOrTitles: [value])?.first { return match }
    guard let fallback = store.defaultCalendarForNewEvents else {
        fail("no default calendar is configured; pass \"calendar\" explicitly", code: "not_found")
    }
    return fallback
}

/// Events matching a window. EventKit caps a single predicate at four years,
/// so long ranges are fetched in chunks.
func fetchEvents(start: Date, end: Date, in cals: [EKCalendar]?) -> [EKEvent] {
    guard start < end else { return [] }
    let maxSpan: TimeInterval = 60 * 60 * 24 * 365 * 3
    var results: [EKEvent] = []
    var cursor = start
    while cursor < end {
        let chunkEnd = min(cursor.addingTimeInterval(maxSpan), end)
        let predicate = store.predicateForEvents(withStart: cursor, end: chunkEnd, calendars: cals)
        results.append(contentsOf: store.events(matching: predicate))
        cursor = chunkEnd
    }
    // Chunk boundaries can return the same occurrence twice.
    var seen = Set<String>()
    return results
        .filter { seen.insert("\($0.eventIdentifier ?? "")|\($0.occurrenceDate.timeIntervalSince1970)").inserted }
        .sorted { $0.startDate < $1.startDate }
}

/// Resolves an event, preferring the specific occurrence when one is named.
func findEvent(id: String, occurrence: Date?) -> EKEvent? {
    if let occurrence {
        let window = fetchEvents(start: occurrence.addingTimeInterval(-86_400),
                                 end: occurrence.addingTimeInterval(86_400 * 2),
                                 in: nil)
        if let hit = window.first(where: {
            $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince(occurrence)) < 60
        }) {
            return hit
        }
    }
    return store.event(withIdentifier: id)
}

func span(from raw: String?) -> EKSpan {
    switch (raw ?? "this").lowercased() {
    case "future", "futureevents", "this_and_future": return .futureEvents
    default: return .thisEvent
    }
}

// MARK: - Mutation helpers

func applyAlarms(to event: EKEvent) {
    guard let alarms = root["alarms"] as? [Any] else { return }
    event.alarms?.forEach { event.removeAlarm($0) }
    for entry in alarms {
        if let minutes = (entry as? NSNumber)?.doubleValue {
            event.addAlarm(EKAlarm(relativeOffset: -minutes * 60))
        } else if let dict = entry as? [String: Any] {
            if let minutes = (dict["minutesBefore"] as? NSNumber)?.doubleValue {
                event.addAlarm(EKAlarm(relativeOffset: -minutes * 60))
            } else if let at = dict["at"] as? String, let date = parseDate(at) {
                event.addAlarm(EKAlarm(absoluteDate: date))
            }
        }
    }
}

func applyRecurrence(to event: EKEvent) {
    guard root["recurrence"] != nil else { return }
    if root["recurrence"] is NSNull {
        event.recurrenceRules = nil
        return
    }
    guard let spec = root["recurrence"] as? [String: Any] else {
        fail("\"recurrence\" must be an object or null", code: "bad_request")
    }
    let frequencyName = (spec["frequency"] as? String ?? "").lowercased()
    let frequency: EKRecurrenceFrequency
    switch frequencyName {
    case "daily": frequency = .daily
    case "weekly": frequency = .weekly
    case "monthly": frequency = .monthly
    case "yearly": frequency = .yearly
    default: fail("recurrence.frequency must be daily, weekly, monthly or yearly", code: "bad_request")
    }

    let interval = max(1, (spec["interval"] as? NSNumber)?.intValue ?? 1)

    var days: [EKRecurrenceDayOfWeek]?
    if let names = spec["daysOfWeek"] as? [String] {
        let lookup: [String: EKWeekday] = [
            "su": .sunday, "sun": .sunday, "sunday": .sunday,
            "mo": .monday, "mon": .monday, "monday": .monday,
            "tu": .tuesday, "tue": .tuesday, "tuesday": .tuesday,
            "we": .wednesday, "wed": .wednesday, "wednesday": .wednesday,
            "th": .thursday, "thu": .thursday, "thursday": .thursday,
            "fr": .friday, "fri": .friday, "friday": .friday,
            "sa": .saturday, "sat": .saturday, "saturday": .saturday,
        ]
        days = names.map { name -> EKRecurrenceDayOfWeek in
            guard let weekday = lookup[name.lowercased()] else {
                fail("unknown weekday \"\(name)\"", code: "bad_request")
            }
            return EKRecurrenceDayOfWeek(weekday)
        }
    }

    var recurrenceEnd: EKRecurrenceEnd?
    if let until = spec["until"] as? String, let date = parseDate(until) {
        recurrenceEnd = EKRecurrenceEnd(end: date)
    } else if let count = (spec["count"] as? NSNumber)?.intValue, count > 0 {
        recurrenceEnd = EKRecurrenceEnd(occurrenceCount: count)
    }

    let rule = EKRecurrenceRule(recurrenceWith: frequency,
                                interval: interval,
                                daysOfTheWeek: days,
                                daysOfTheMonth: nil,
                                monthsOfTheYear: nil,
                                weeksOfTheYear: nil,
                                daysOfTheYear: nil,
                                setPositions: nil,
                                end: recurrenceEnd)
    event.recurrenceRules = [rule]
}

func applyAvailability(to event: EKEvent) {
    guard let raw = str("availability") else { return }
    switch raw.lowercased() {
    case "busy": event.availability = .busy
    case "free": event.availability = .free
    case "tentative": event.availability = .tentative
    case "unavailable": event.availability = .unavailable
    default: fail("availability must be busy, free, tentative or unavailable", code: "bad_request")
    }
}

// MARK: - Commands

switch command {

case "calendars":
    let all = store.calendars(for: .event).sorted { $0.title < $1.title }
    succeed([
        "calendars": all.map { serialize(calendar: $0) },
        "defaultCalendarId": (store.defaultCalendarForNewEvents?.calendarIdentifier ?? NSNull()) as Any,
    ])

case "events":
    let start = requiredDate("start")
    let end = requiredDate("end")
    let cals = calendars(fromIdsOrTitles: strings("calendars"))
    let limit = Int(num("limit") ?? 200)
    let all = fetchEvents(start: start, end: end, in: cals)
    let detailed = bool("detailed") ?? false
    succeed([
        "events": all.prefix(limit).map { serialize(event: $0, detailed: detailed) },
        "total": all.count,
        "truncated": all.count > limit,
        "range": ["start": iso(start), "end": iso(end)],
    ])

case "search":
    guard let query = str("query") else { fail("missing \"query\"", code: "bad_request") }
    let start = optionalDate("start") ?? Date().addingTimeInterval(-60 * 60 * 24 * 365)
    let end = optionalDate("end") ?? Date().addingTimeInterval(60 * 60 * 24 * 365)
    let cals = calendars(fromIdsOrTitles: strings("calendars"))
    let limit = Int(num("limit") ?? 50)
    let needle = query.lowercased()

    let matches = fetchEvents(start: start, end: end, in: cals).filter { ev in
        let haystack = [ev.title, ev.location, ev.notes]
            .compactMap { $0?.lowercased() }
        return haystack.contains { $0.contains(needle) }
    }
    succeed([
        "events": matches.prefix(limit).map { serialize(event: $0, detailed: bool("detailed") ?? false) },
        "total": matches.count,
        "truncated": matches.count > limit,
        "query": query,
    ])

case "get":
    guard let id = str("id") else { fail("missing \"id\"", code: "bad_request") }
    guard let event = findEvent(id: id, occurrence: optionalDate("occurrenceStart")) else {
        fail("no event with id \(id)", code: "not_found")
    }
    succeed(serialize(event: event, detailed: true))

case "create":
    guard let title = str("title") else { fail("missing \"title\"", code: "bad_request") }
    let calendar = resolveCalendar(str("calendar"))
    guard calendar.allowsContentModifications else {
        fail("calendar \"\(calendar.title)\" is read-only", code: "read_only")
    }

    let event = EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = title
    event.isAllDay = bool("allDay") ?? false

    let start = requiredDate("start")
    event.startDate = start
    if let end = optionalDate("end") {
        event.endDate = end
    } else if event.isAllDay {
        event.endDate = start
    } else {
        let minutes = num("durationMinutes") ?? 60
        event.endDate = start.addingTimeInterval(minutes * 60)
    }
    guard event.endDate >= event.startDate else {
        fail("end must not be before start", code: "bad_request")
    }

    if let location = str("location") { event.location = location }
    if let notes = str("notes") { event.notes = notes }
    if let url = str("url") { event.url = URL(string: url) }
    applyAlarms(to: event)
    applyRecurrence(to: event)
    applyAvailability(to: event)

    do {
        try store.save(event, span: .futureEvents, commit: true)
    } catch {
        fail("could not save event: \(error.localizedDescription)", code: "save_failed")
    }
    succeed(serialize(event: event, detailed: true))

case "update":
    guard let id = str("id") else { fail("missing \"id\"", code: "bad_request") }
    guard let event = findEvent(id: id, occurrence: optionalDate("occurrenceStart")) else {
        fail("no event with id \(id)", code: "not_found")
    }
    guard event.calendar?.allowsContentModifications ?? false else {
        fail("event lives in a read-only calendar", code: "read_only")
    }

    if let title = str("title") { event.title = title }
    if let allDay = bool("allDay") { event.isAllDay = allDay }
    if let start = optionalDate("start") {
        let duration = event.endDate.timeIntervalSince(event.startDate)
        event.startDate = start
        // Keep the original duration unless a new end is supplied too.
        if root["end"] == nil { event.endDate = start.addingTimeInterval(duration) }
    }
    if let end = optionalDate("end") { event.endDate = end }
    if root["location"] != nil { event.location = str("location") }
    if root["notes"] != nil { event.notes = str("notes") }
    if root["url"] != nil { event.url = str("url").flatMap { URL(string: $0) } }
    if let calendarName = str("calendar") {
        let target = resolveCalendar(calendarName)
        guard target.allowsContentModifications else {
            fail("calendar \"\(target.title)\" is read-only", code: "read_only")
        }
        event.calendar = target
    }
    applyAlarms(to: event)
    applyRecurrence(to: event)
    applyAvailability(to: event)

    guard event.endDate >= event.startDate else {
        fail("end must not be before start", code: "bad_request")
    }

    do {
        try store.save(event, span: span(from: str("span")), commit: true)
    } catch {
        fail("could not save event: \(error.localizedDescription)", code: "save_failed")
    }
    succeed(serialize(event: event, detailed: true))

case "delete":
    guard let id = str("id") else { fail("missing \"id\"", code: "bad_request") }
    guard let event = findEvent(id: id, occurrence: optionalDate("occurrenceStart")) else {
        fail("no event with id \(id)", code: "not_found")
    }
    guard event.calendar?.allowsContentModifications ?? false else {
        fail("event lives in a read-only calendar", code: "read_only")
    }
    let summary = serialize(event: event)
    do {
        try store.remove(event, span: span(from: str("span")), commit: true)
    } catch {
        fail("could not delete event: \(error.localizedDescription)", code: "delete_failed")
    }
    succeed(["deleted": summary])

case "free":
    let start = requiredDate("start")
    let end = requiredDate("end")
    let duration = (num("durationMinutes") ?? 30) * 60
    let dayStartHour = Int(num("dayStartHour") ?? 9)
    let dayEndHour = Int(num("dayEndHour") ?? 18)
    let includeWeekends = bool("includeWeekends") ?? false
    let cals = calendars(fromIdsOrTitles: strings("calendars"))
    let limit = Int(num("limit") ?? 20)

    guard dayStartHour < dayEndHour else {
        fail("dayStartHour must be before dayEndHour", code: "bad_request")
    }

    // Busy intervals: skip anything explicitly marked free, plus all-day markers.
    var busy: [(Date, Date)] = fetchEvents(start: start, end: end, in: cals)
        .filter { $0.availability != .free && $0.status != .canceled && !$0.isAllDay }
        .map { ($0.startDate, $0.endDate) }
        .sorted { $0.0 < $1.0 }

    var merged: [(Date, Date)] = []
    for interval in busy {
        if let last = merged.last, interval.0 <= last.1 {
            merged[merged.count - 1].1 = max(last.1, interval.1)
        } else {
            merged.append(interval)
        }
    }
    busy = merged

    let cal = Calendar.current
    var slots: [[String: Any]] = []
    var day = cal.startOfDay(for: start)

    while day < end && slots.count < limit {
        defer { day = cal.date(byAdding: .day, value: 1, to: day)! }

        let weekday = cal.component(.weekday, from: day)
        if !includeWeekends && (weekday == 1 || weekday == 7) { continue }

        guard
            let windowStart = cal.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: day),
            let windowEnd = cal.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: day)
        else { continue }

        var cursor = max(windowStart, start)
        let stop = min(windowEnd, end)

        for (busyStart, busyEnd) in busy where busyEnd > cursor && busyStart < stop {
            if busyStart.timeIntervalSince(cursor) >= duration {
                slots.append(["start": iso(cursor), "end": iso(busyStart),
                              "minutes": Int(busyStart.timeIntervalSince(cursor) / 60)])
            }
            cursor = max(cursor, busyEnd)
        }
        if stop.timeIntervalSince(cursor) >= duration {
            slots.append(["start": iso(cursor), "end": iso(stop),
                          "minutes": Int(stop.timeIntervalSince(cursor) / 60)])
        }
    }

    succeed([
        "slots": Array(slots.prefix(limit)),
        "durationMinutes": Int(duration / 60),
        "searched": ["start": iso(start), "end": iso(end),
                     "dayStartHour": dayStartHour, "dayEndHour": dayEndHour,
                     "includeWeekends": includeWeekends],
    ])

default:
    fail("unknown command \"\(command)\"", code: "bad_request")
}
