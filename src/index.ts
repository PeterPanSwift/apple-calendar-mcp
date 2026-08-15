#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

import { BridgeError, callBridge } from "./bridge.js";
import {
  CalendarSummary,
  EventSummary,
  TZ,
  daysFrom,
  formatCalendars,
  formatEventDetail,
  formatEvents,
  localISO,
  parseLocal,
  startOfToday,
} from "./format.js";

const server = new McpServer(
  { name: "apple-calendar", version: "0.1.0" },
  {
    instructions:
      `Reads and edits the local Apple Calendar (macOS) via EventKit. All times are in ${TZ} ` +
      `unless a timestamp carries an explicit offset. Date arguments accept "2026-08-15", ` +
      `"2026-08-15T14:30", or a full ISO-8601 string. Recurring events are returned as individual ` +
      `occurrences; to edit one, pass both "id" and "occurrence_start" and choose a "span".`,
  },
);

type ToolResult = { content: Array<{ type: "text"; text: string }>; isError?: boolean };

const text = (body: string): ToolResult => ({ content: [{ type: "text", text: body }] });

/** Turns bridge failures into readable tool errors instead of transport-level crashes. */
async function guard(fn: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await fn();
  } catch (err) {
    const message =
      err instanceof BridgeError ? `${err.message} (${err.code})` : (err as Error).message;
    return { content: [{ type: "text", text: `Calendar error: ${message}` }], isError: true };
  }
}

const dateArg = (what: string) =>
  z.string().describe(`${what}. Accepts "YYYY-MM-DD", "YYYY-MM-DDTHH:mm", or full ISO-8601.`);

const recurrenceSchema = z
  .object({
    frequency: z.enum(["daily", "weekly", "monthly", "yearly"]),
    interval: z.number().int().min(1).optional().describe("Repeat every N periods. Default 1."),
    days_of_week: z
      .array(z.enum(["SU", "MO", "TU", "WE", "TH", "FR", "SA"]))
      .optional()
      .describe("Weekly recurrences only."),
    until: z.string().optional().describe("Repeat until this date (inclusive)."),
    count: z.number().int().min(1).optional().describe("Stop after this many occurrences."),
  })
  .describe("Repeat rule. Set to null when updating to remove recurrence.");

function toBridgeRecurrence(r: z.infer<typeof recurrenceSchema>) {
  return {
    frequency: r.frequency,
    interval: r.interval,
    daysOfWeek: r.days_of_week,
    until: r.until,
    count: r.count,
  };
}

// ---------------------------------------------------------------- calendars

server.registerTool(
  "list_calendars",
  {
    title: "List calendars",
    description:
      "List every calendar available in Apple Calendar, with its identifier, source account, " +
      "and whether it can be written to. Use this before creating events in a specific calendar.",
    inputSchema: {},
    annotations: { readOnlyHint: true },
  },
  async () =>
    guard(async () => {
      const data = (await callBridge("calendars")) as {
        calendars: CalendarSummary[];
        defaultCalendarId: string | null;
      };
      return text(
        `Timezone: ${TZ}\n\n${formatCalendars(data.calendars, data.defaultCalendarId)}`,
      );
    }),
);

// ------------------------------------------------------------------- events

server.registerTool(
  "list_events",
  {
    title: "List events",
    description:
      "List calendar events in a date range, expanded so each occurrence of a recurring event " +
      "appears separately. Defaults to the next 7 days starting today.",
    inputSchema: {
      start: dateArg("Start of the range").optional(),
      end: dateArg("End of the range").optional(),
      days: z
        .number()
        .int()
        .min(1)
        .max(400)
        .optional()
        .describe("Shortcut for a range of N days starting at `start` (default today)."),
      calendars: z
        .array(z.string())
        .optional()
        .describe("Restrict to these calendar names or ids. Omit for all calendars."),
      detailed: z
        .boolean()
        .optional()
        .describe("Include notes, attendees and alerts. Default false."),
      limit: z.number().int().min(1).max(1000).optional().describe("Max events. Default 200."),
    },
    annotations: { readOnlyHint: true },
  },
  async ({ start, end, days, calendars, detailed, limit }) =>
    guard(async () => {
      const from = start ?? localISO(startOfToday());
      const to = end ?? localISO(daysFrom(start ? parseLocal(start) : startOfToday(), days ?? 7));

      const data = (await callBridge("events", {
        start: from,
        end: to,
        calendars,
        detailed: detailed ?? false,
        limit: limit ?? 200,
      })) as { events: EventSummary[]; total: number; truncated: boolean };

      const header = `${data.total} event(s) from ${from} to ${to} (${TZ})`;
      const footer = data.truncated ? `\n\n(showing the first ${limit ?? 200})` : "";
      return text(`${header}\n\n${formatEvents(data.events, { detailed })}${footer}`);
    }),
);

server.registerTool(
  "search_events",
  {
    title: "Search events",
    description:
      "Find events whose title, location or notes contain the given text. Searches one year " +
      "back and one year forward unless a range is given.",
    inputSchema: {
      query: z.string().min(1).describe("Text to look for (case-insensitive substring)."),
      start: dateArg("Earliest event to consider").optional(),
      end: dateArg("Latest event to consider").optional(),
      calendars: z.array(z.string()).optional().describe("Restrict to these calendar names or ids."),
      detailed: z.boolean().optional(),
      limit: z.number().int().min(1).max(500).optional().describe("Max results. Default 50."),
    },
    annotations: { readOnlyHint: true },
  },
  async ({ query, start, end, calendars, detailed, limit }) =>
    guard(async () => {
      const data = (await callBridge("search", {
        query,
        start,
        end,
        calendars,
        detailed: detailed ?? false,
        limit: limit ?? 50,
      })) as { events: EventSummary[]; total: number; truncated: boolean };

      const header = `${data.total} event(s) matching "${query}"`;
      const footer = data.truncated ? `\n\n(showing the first ${limit ?? 50})` : "";
      return text(`${header}\n\n${formatEvents(data.events, { detailed })}${footer}`);
    }),
);

server.registerTool(
  "get_event",
  {
    title: "Get event",
    description:
      "Fetch one event in full, including notes, attendees, alerts and its repeat rule.",
    inputSchema: {
      id: z.string().describe("Event id from list_events or search_events."),
      occurrence_start: z
        .string()
        .optional()
        .describe("For recurring events, the occurrenceStart of the instance you mean."),
    },
    annotations: { readOnlyHint: true },
  },
  async ({ id, occurrence_start }) =>
    guard(async () => {
      const ev = (await callBridge("get", {
        id,
        occurrenceStart: occurrence_start,
      })) as EventSummary;
      return text(formatEventDetail(ev));
    }),
);

server.registerTool(
  "create_event",
  {
    title: "Create event",
    description:
      "Create a new event in Apple Calendar. Writes to the default calendar unless one is named. " +
      "Attendees cannot be added — EventKit does not allow it; put people in the notes instead.",
    inputSchema: {
      title: z.string().min(1).describe("Event title."),
      start: dateArg("When the event starts"),
      end: dateArg("When the event ends").optional(),
      duration_minutes: z
        .number()
        .min(1)
        .optional()
        .describe("Used when `end` is omitted. Default 60."),
      all_day: z.boolean().optional().describe("Default false."),
      calendar: z.string().optional().describe("Calendar name or id. Defaults to the system default."),
      location: z.string().optional(),
      notes: z.string().optional(),
      url: z.string().optional(),
      alarms: z
        .array(z.number())
        .optional()
        .describe("Alerts, in minutes before the start. e.g. [10, 60]."),
      availability: z.enum(["busy", "free", "tentative", "unavailable"]).optional(),
      recurrence: recurrenceSchema.optional(),
    },
  },
  async (args) =>
    guard(async () => {
      const ev = (await callBridge("create", {
        title: args.title,
        start: args.start,
        end: args.end,
        durationMinutes: args.duration_minutes,
        allDay: args.all_day,
        calendar: args.calendar,
        location: args.location,
        notes: args.notes,
        url: args.url,
        alarms: args.alarms,
        availability: args.availability,
        recurrence: args.recurrence ? toBridgeRecurrence(args.recurrence) : undefined,
      })) as EventSummary;
      return text(`Created:\n\n${formatEventDetail(ev)}`);
    }),
);

server.registerTool(
  "update_event",
  {
    title: "Update event",
    description:
      "Change fields on an existing event. Only the fields you pass are modified. Moving `start` " +
      "without `end` keeps the original duration. For a recurring event, pass `occurrence_start` " +
      "and set `span` to control whether one instance or the whole future series changes.",
    inputSchema: {
      id: z.string().describe("Event id from list_events or search_events."),
      occurrence_start: z
        .string()
        .optional()
        .describe("For recurring events, the occurrenceStart of the instance you mean."),
      span: z
        .enum(["this", "future"])
        .optional()
        .describe("'this' edits one occurrence, 'future' edits it and all later ones. Default 'this'."),
      title: z.string().optional(),
      start: dateArg("New start").optional(),
      end: dateArg("New end").optional(),
      all_day: z.boolean().optional(),
      calendar: z.string().optional().describe("Move the event to this calendar."),
      location: z.string().optional().describe("Pass an empty string to clear."),
      notes: z.string().optional().describe("Pass an empty string to clear."),
      url: z.string().optional().describe("Pass an empty string to clear."),
      alarms: z.array(z.number()).optional().describe("Replaces all alerts. [] removes them."),
      availability: z.enum(["busy", "free", "tentative", "unavailable"]).optional(),
      recurrence: recurrenceSchema.nullable().optional(),
    },
  },
  async (args) =>
    guard(async () => {
      const payload: Record<string, unknown> = {
        id: args.id,
        occurrenceStart: args.occurrence_start,
        span: args.span,
        title: args.title,
        start: args.start,
        end: args.end,
        allDay: args.all_day,
        calendar: args.calendar,
        availability: args.availability,
      };
      // These are meaningful when explicitly set to an empty value, so only
      // forward the key when the caller actually supplied it.
      if (args.location !== undefined) payload.location = args.location;
      if (args.notes !== undefined) payload.notes = args.notes;
      if (args.url !== undefined) payload.url = args.url;
      if (args.alarms !== undefined) payload.alarms = args.alarms;
      if (args.recurrence !== undefined) {
        payload.recurrence = args.recurrence === null ? null : toBridgeRecurrence(args.recurrence);
      }

      const ev = (await callBridge("update", payload)) as EventSummary;
      return text(`Updated:\n\n${formatEventDetail(ev)}`);
    }),
);

server.registerTool(
  "delete_event",
  {
    title: "Delete event",
    description:
      "Delete an event. For a recurring event, pass `occurrence_start` and set `span` to choose " +
      "between removing one occurrence or the whole remaining series. This cannot be undone.",
    inputSchema: {
      id: z.string().describe("Event id from list_events or search_events."),
      occurrence_start: z
        .string()
        .optional()
        .describe("For recurring events, the occurrenceStart of the instance you mean."),
      span: z
        .enum(["this", "future"])
        .optional()
        .describe("'this' removes one occurrence, 'future' removes it and all later ones. Default 'this'."),
    },
    annotations: { destructiveHint: true },
  },
  async ({ id, occurrence_start, span }) =>
    guard(async () => {
      const data = (await callBridge("delete", {
        id,
        occurrenceStart: occurrence_start,
        span,
      })) as { deleted: EventSummary };
      const ev = data.deleted;
      return text(`Deleted "${ev.title}" (${ev.start} → ${ev.end}) from ${ev.calendar}.`);
    }),
);

server.registerTool(
  "find_free_time",
  {
    title: "Find free time",
    description:
      "Find open slots of at least N minutes within working hours, treating any event marked busy " +
      "or tentative as blocking. All-day events and events marked free are ignored.",
    inputSchema: {
      duration_minutes: z.number().min(5).describe("How long the slot needs to be."),
      start: dateArg("Earliest date to consider").optional(),
      end: dateArg("Latest date to consider").optional(),
      days: z.number().int().min(1).max(60).optional().describe("Search N days from `start`. Default 7."),
      day_start_hour: z.number().int().min(0).max(23).optional().describe("Working day start. Default 9."),
      day_end_hour: z.number().int().min(1).max(24).optional().describe("Working day end. Default 18."),
      include_weekends: z.boolean().optional().describe("Default false."),
      calendars: z.array(z.string()).optional().describe("Only treat these calendars as busy."),
      limit: z.number().int().min(1).max(100).optional().describe("Max slots. Default 20."),
    },
    annotations: { readOnlyHint: true },
  },
  async (args) =>
    guard(async () => {
      const from = args.start ?? localISO(startOfToday());
      const to =
        args.end ??
        localISO(daysFrom(args.start ? parseLocal(args.start) : startOfToday(), args.days ?? 7));

      const data = (await callBridge("free", {
        start: from,
        end: to,
        durationMinutes: args.duration_minutes,
        dayStartHour: args.day_start_hour,
        dayEndHour: args.day_end_hour,
        includeWeekends: args.include_weekends,
        calendars: args.calendars,
        limit: args.limit,
      })) as { slots: Array<{ start: string; end: string; minutes: number }> };

      if (data.slots.length === 0) {
        return text(`No free slot of ${args.duration_minutes} minutes between ${from} and ${to}.`);
      }

      const fmt = new Intl.DateTimeFormat(undefined, {
        weekday: "short",
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      });
      const lines = data.slots.map((s) => {
        const endTime = new Intl.DateTimeFormat(undefined, {
          hour: "2-digit",
          minute: "2-digit",
        }).format(new Date(s.end));
        return `  ${fmt.format(new Date(s.start))} – ${endTime}  (${s.minutes} min)`;
      });
      return text(
        `${data.slots.length} open slot(s) of at least ${args.duration_minutes} min (${TZ}):\n\n${lines.join("\n")}`,
      );
    }),
);

// ------------------------------------------------------------------ startup

const transport = new StdioServerTransport();
await server.connect(transport);
