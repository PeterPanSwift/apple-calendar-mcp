export interface CalendarSummary {
  id: string;
  title: string;
  type: string;
  source: string;
  color?: string;
  allowsModification: boolean;
  isSubscribed: boolean;
}

export interface EventSummary {
  id: string;
  title: string;
  start: string;
  end: string;
  allDay: boolean;
  calendar: string;
  calendarId: string;
  isRecurring: boolean;
  availability: string;
  editable: boolean;
  occurrenceStart?: string;
  location?: string;
  url?: string;
  notes?: string;
  status?: string;
  organizer?: string;
  attendees?: Array<{ name: string; email: string; status: string }>;
  alarms?: Array<{ minutesBefore?: number; at?: string }>;
  recurrence?: Array<Record<string, unknown>>;
}

export const TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;

/** ISO-like local timestamp, no offset — the bridge reads bare timestamps as local. */
export function localISO(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
  );
}

/** `new Date("2026-08-15")` is UTC midnight, which lands on the previous day in
 *  western timezones. Date-only strings must be read as local midnight. */
export function parseLocal(value: string): Date {
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim());
  if (dateOnly) return new Date(+dateOnly[1], +dateOnly[2] - 1, +dateOnly[3]);
  return new Date(value);
}

export function startOfToday(): Date {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
}

export function daysFrom(base: Date, days: number): Date {
  const d = new Date(base);
  d.setDate(d.getDate() + days);
  return d;
}

const dayFmt = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  year: "numeric",
  month: "short",
  day: "numeric",
});
const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });

const dayKey = (iso: string) => new Date(iso).toDateString();

export function formatEvents(events: EventSummary[], opts: { detailed?: boolean } = {}): string {
  if (events.length === 0) return "No events found.";

  const lines: string[] = [];
  let currentDay = "";

  for (const ev of events) {
    const key = dayKey(ev.start);
    if (key !== currentDay) {
      currentDay = key;
      if (lines.length) lines.push("");
      lines.push(dayFmt.format(new Date(ev.start)));
    }

    const when = ev.allDay
      ? "all day"
      : `${timeFmt.format(new Date(ev.start))}–${timeFmt.format(new Date(ev.end))}`;

    const tags: string[] = [ev.calendar];
    if (ev.isRecurring) tags.push("recurring");
    if (ev.availability === "free") tags.push("free");
    if (ev.availability === "tentative") tags.push("tentative");
    if (!ev.editable) tags.push("read-only");

    lines.push(`  ${when}  ${ev.title}  [${tags.join(", ")}]`);
    if (ev.location) lines.push(`      at ${ev.location}`);

    if (opts.detailed) {
      if (ev.attendees?.length) {
        const who = ev.attendees.map((a) => `${a.name} (${a.status})`).join(", ");
        lines.push(`      with ${who}`);
      }
      if (ev.alarms?.length) {
        const alerts = ev.alarms
          .map((a) => (a.minutesBefore !== undefined ? `${a.minutesBefore}m before` : a.at))
          .join(", ");
        lines.push(`      alerts: ${alerts}`);
      }
      if (ev.url) lines.push(`      url: ${ev.url}`);
      if (ev.notes) lines.push(`      notes: ${ev.notes.replace(/\s+/g, " ").slice(0, 300)}`);
    }

    const idLine = ev.occurrenceStart
      ? `      id: ${ev.id}  occurrenceStart: ${ev.occurrenceStart}`
      : `      id: ${ev.id}`;
    lines.push(idLine);
  }

  return lines.join("\n");
}

export function formatEventDetail(ev: EventSummary): string {
  const lines = [
    ev.title,
    `  when:      ${ev.allDay ? `${dayFmt.format(new Date(ev.start))} (all day)` : `${dayFmt.format(new Date(ev.start))} ${timeFmt.format(new Date(ev.start))}–${timeFmt.format(new Date(ev.end))}`}`,
    `  calendar:  ${ev.calendar}`,
  ];
  if (ev.location) lines.push(`  location:  ${ev.location}`);
  if (ev.url) lines.push(`  url:       ${ev.url}`);
  if (ev.organizer) lines.push(`  organizer: ${ev.organizer}`);
  if (ev.attendees?.length) {
    lines.push("  attendees:");
    for (const a of ev.attendees) lines.push(`    - ${a.name} <${a.email}> — ${a.status}`);
  }
  if (ev.alarms?.length) {
    const alerts = ev.alarms
      .map((a) => (a.minutesBefore !== undefined ? `${a.minutesBefore}m before` : a.at))
      .join(", ");
    lines.push(`  alerts:    ${alerts}`);
  }
  if (ev.recurrence?.length) {
    lines.push(`  repeats:   ${JSON.stringify(ev.recurrence)}`);
  }
  lines.push(`  status:    ${ev.status ?? "none"} / ${ev.availability}`);
  if (ev.notes) lines.push(`  notes:\n${ev.notes.split("\n").map((l) => `    ${l}`).join("\n")}`);
  lines.push(`  id:        ${ev.id}`);
  if (ev.occurrenceStart) lines.push(`  occurrenceStart: ${ev.occurrenceStart}`);
  return lines.join("\n");
}

export function formatCalendars(
  calendars: CalendarSummary[],
  defaultCalendarId: string | null,
): string {
  if (calendars.length === 0) return "No calendars found.";
  return calendars
    .map((c) => {
      const tags = [c.type, c.source];
      if (!c.allowsModification) tags.push("read-only");
      if (c.id === defaultCalendarId) tags.push("default");
      return `${c.title}  [${tags.join(", ")}]\n    id: ${c.id}`;
    })
    .join("\n");
}
