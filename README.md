# Apple Calendar MCP Server

An MCP server that lets an AI assistant read and edit the local macOS Calendar, backed by **EventKit** — so recurring events expand into the occurrences that actually happen.

**[English](#english) · [中文](#中文)**

---

<a id="english"></a>

## English

> [切換到中文 ↓](#中文)

### Why EventKit, not AppleScript

Calendar.app's scripting interface returns only the *master* event for a recurring series, stamped with its original creation date. Ask it "what's on my calendar today" and a weekly meeting created back in January simply never appears. EventKit's `events(matching:)` has no such problem, so every calendar operation goes through it.

### Architecture

```
MCP client  ──stdio/JSON-RPC──▶  Node MCP server (src/*.ts)
                                        │  one JSON request per invocation
                                        ▼
                                 calendar-bridge  (Swift + EventKit)
                                        │
                                        ▼
                                 macOS Calendar database
```

Two layers because the mature MCP SDK is in TypeScript, but only EventKit handles recurrence, availability and alarms correctly. The bridge is a tiny Swift CLI: it reads one JSON request on stdin and writes one JSON response on stdout.

### Requirements

- macOS with Xcode command line tools (for `swiftc`)
- Node.js 18+

### Build

```bash
npm install && npm run build
```

This compiles the Swift bridge to `bin/calendar-bridge` and the TypeScript to `dist/`.

### Granting calendar access

macOS will not hand calendar access to a process without a usage description, so `Info.plist` is linked directly into the binary's `__TEXT,__info_plist` section and the result is ad-hoc signed.

The permission prompt is shown for **whichever app launches the server** — Terminal, the Claude desktop app, your IDE. The easiest way to trigger it is to run the bridge once from a terminal:

```bash
echo '{"command":"calendars"}' | ./bin/calendar-bridge
```

If no prompt appears, or you dismissed it, enable the app under **System Settings → Privacy & Security → Calendars**, then quit and reopen that app.

Permission follows the calling app, not this binary. Switch clients and you grant it again.

### Registering the server

**Claude Code**

```bash
claude mcp add apple-calendar -- node "/absolute/path/to/dist/index.js"
```

Or just open the project directory — the checked-in `.mcp.json` is picked up automatically.

**Claude Desktop** — in `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "apple-calendar": {
      "command": "node",
      "args": ["/absolute/path/to/dist/index.js"]
    }
  }
}
```

**Claude Cowork** — install the packaged plugin, and make sure the task runs **On your computer**. Local MCP servers do not run in cloud sessions, and EventKit is a macOS API that cannot execute inside Cowork's Linux sandbox. See [INSTALL.md](INSTALL.md) for the full walkthrough (written in Chinese).

### Tools

| Tool | What it does |
| --- | --- |
| `list_calendars` | Every calendar, its source account, whether it is writable, and which is the default |
| `list_events` | Events in a date range (default: today plus 7 days), recurrences expanded |
| `search_events` | Substring match against title, location and notes (default: one year either side) |
| `get_event` | One event in full — notes, attendees, alarms, repeat rule |
| `create_event` | New event with location, notes, URL, alarms, recurrence and availability |
| `update_event` | Only the fields you pass; moving `start` without `end` preserves the duration |
| `delete_event` | Remove an event — cannot be undone |
| `find_free_time` | Open slots of at least N minutes within working hours |

#### Date formats

Every date argument accepts `2026-08-15`, `2026-08-15T14:30`, or a full ISO-8601 string. A timestamp without an offset is read as local time.

#### Recurring events

`list_events` returns both an `id` and an `occurrenceStart` for recurring events. To change or delete a single instance, pass both, and use `span` to choose the scope:

- `span: "this"` (default) — only this occurrence
- `span: "future"` — this occurrence and every later one

Creating a repeating event:

```json
{
  "title": "Weekly sync",
  "start": "2026-08-17T10:00",
  "duration_minutes": 30,
  "recurrence": { "frequency": "weekly", "days_of_week": ["MO"], "count": 12 }
}
```

Pass `"recurrence": null` to `update_event` to strip the repeat rule.

#### Finding free time

`find_free_time` treats anything marked busy or tentative as blocking, and ignores all-day events and events marked free. Working hours default to 09:00–18:00 excluding weekends; all of that is adjustable.

### Known limitations

- **Attendees cannot be added.** EventKit's `EKParticipant` is read-only — this is an API constraint, not an omission. Reading existing attendees and their responses works fine. To invite people, list them in the notes or send the invitation from Calendar.app.
- **Reminders are not supported.** That is a separate EventKit entity behind a separate permission, deliberately out of scope.
- **Clearing a field in `update_event`** takes an empty string (`"location": ""`), not `null`.
- **Permission follows the calling app.** A new client means a new grant.

### Development

```bash
npm run build:swift   # rebuild the Swift bridge only
npm run build:ts      # recompile TypeScript only
npm run smoke         # start a real MCP client, list tools, call three read-only ones
```

Talking to the bridge directly:

```bash
echo '{"command":"events","start":"2026-08-15","end":"2026-08-22"}' | ./bin/calendar-bridge
```

The bridge location can be overridden with `CALENDAR_BRIDGE_PATH`, which the Cowork plugin build relies on — claude.ai's plugin validator rejects a top-level `bin/` directory, so the binary ships under `libexec/` there instead.

#### Layout

| Path | Role |
| --- | --- |
| `src/swift/main.swift` | The EventKit bridge — every calendar operation lives here |
| `src/swift/Info.plist` | Usage descriptions, linked into the binary |
| `src/bridge.ts` | Spawns the bridge, handles timeouts and error codes |
| `src/index.ts` | MCP server and tool definitions |
| `src/format.ts` | Renders events as text for the model |
| `skills/apple-calendar/` | Skill that teaches Claude when and how to use these tools |
| `scripts/build-swift.sh` | Compile and ad-hoc sign |

---

<a id="中文"></a>

## 中文

> [Back to English ↑](#english)

一個讓 AI 助理讀寫 macOS「行事曆」的 MCP server。底層走 **EventKit**，因此重複性事件會被正確展開成每一次實際發生的時間。

### 為什麼不用 AppleScript

Calendar.app 的 scripting 介面對重複性事件只回傳「母事件」與原始建立日期，不會展開成實際發生的場次。查「今天有什麼會」時，一個一月建立的週會根本不會出現。EventKit 的 `events(matching:)` 沒有這個問題，所以所有行事曆操作都走它。

### 架構

```
MCP client  ──stdio/JSON-RPC──▶  Node MCP server (src/*.ts)
                                        │  一次呼叫一個 JSON 請求
                                        ▼
                                 calendar-bridge  (Swift + EventKit)
                                        │
                                        ▼
                                 macOS 行事曆資料庫
```

拆成兩層的原因：MCP 生態的 SDK 在 TypeScript 最成熟，但只有 EventKit 能正確處理重複事件、忙碌狀態與提醒。橋接程式是一支極小的 Swift CLI，從 stdin 吃一個 JSON 請求、往 stdout 吐一個 JSON 回應。

### 需求

- macOS，且已安裝 Xcode command line tools（需要 `swiftc`）
- Node.js 18 以上

### 編譯

```bash
npm install && npm run build
```

會編出 Swift 橋接程式 `bin/calendar-bridge` 與 TypeScript 的 `dist/`。

### 開啟行事曆權限

macOS 不會把行事曆權限給沒有用途說明的程式，所以 `Info.plist` 用 linker 直接嵌進二進位檔的 `__TEXT,__info_plist` 區段，並做 ad-hoc 簽章。

授權對話框是對**啟動這個 server 的那個 app** 跳出來的——Terminal、Claude 桌面版、你的 IDE。最容易觸發的方式是在終端機直接跑一次橋接程式：

```bash
echo '{"command":"calendars"}' | ./bin/calendar-bridge
```

若沒跳出提示或被拒絕，到**系統設定 → 隱私權與安全性 → 行事曆**把該 app 打開，然後完全結束該 app 再重開。

權限是綁在呼叫端的 app 上，不是綁在這支二進位檔。換一個 client 就要重新授權一次。

### 註冊到 MCP client

**Claude Code**

```bash
claude mcp add apple-calendar -- node "/絕對路徑/dist/index.js"
```

或直接在專案目錄開 Claude Code，會自動載入專案裡的 `.mcp.json`。

**Claude Desktop** — 編輯 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "apple-calendar": {
      "command": "node",
      "args": ["/絕對路徑/dist/index.js"]
    }
  }
}
```

**Claude Cowork** — 安裝打包好的外掛，並且開新工作時一定要選 **On your computer**。本機 MCP server 不會在雲端 session 裡執行，而 EventKit 是 macOS API，在 Cowork 的 Linux 沙箱裡根本跑不起來。完整步驟見 [INSTALL.md](INSTALL.md)。

### 工具

| 工具 | 用途 |
| --- | --- |
| `list_calendars` | 列出所有行事曆、來源帳號、是否可寫入、預設行事曆 |
| `list_events` | 查某區間的事件（預設今天起 7 天），重複事件已展開 |
| `search_events` | 用文字比對標題／地點／備註（預設前後各一年） |
| `get_event` | 取單一事件完整資料：備註、與會者、提醒、重複規則 |
| `create_event` | 建立事件，可設地點、備註、URL、提醒、重複規則、忙碌狀態 |
| `update_event` | 只更新有傳入的欄位；改 `start` 而不給 `end` 會保留原本長度 |
| `delete_event` | 刪除事件（不可復原） |
| `find_free_time` | 在工作時段內找出足夠長度的空檔 |

#### 日期格式

所有日期參數都接受 `2026-08-15`、`2026-08-15T14:30`、或完整 ISO-8601。沒有時區標示的一律當成本機時區。

#### 重複性事件

`list_events` 對重複事件會同時回傳 `id` 與 `occurrenceStart`。要改動或刪除單一場次，兩個都要傳，並用 `span` 決定範圍：

- `span: "this"`（預設）— 只影響這一場
- `span: "future"` — 影響這一場與之後所有場次

建立重複事件：

```json
{
  "title": "週會",
  "start": "2026-08-17T10:00",
  "duration_minutes": 30,
  "recurrence": { "frequency": "weekly", "days_of_week": ["MO"], "count": 12 }
}
```

`update_event` 傳 `"recurrence": null` 可以把重複規則拿掉。

#### 找空檔

`find_free_time` 把標記為 busy 或 tentative 的事件視為佔用，忽略整天事件與標記為 free 的事件。預設工作時段 09:00–18:00、不含週末，都可以用參數調整。

### 已知限制

- **無法新增與會者。** EventKit 的 `EKParticipant` 是唯讀的，這是 API 層的硬限制。讀取既有與會者與其回覆狀態沒有問題。想邀請人請把名單寫在備註裡，或直接用 Calendar.app 送出邀請。
- **不支援提醒事項（Reminders）。** 那是另一個 EventKit entity 與另一組權限，刻意不納入範圍。
- **`update_event` 清空欄位**要傳空字串（`"location": ""`），不是 `null`。
- **權限跟著呼叫端的 app 走。** 換一個 client 就要重新授權一次。

### 開發

```bash
npm run build:swift   # 只重建 Swift 橋接程式
npm run build:ts      # 只重編 TypeScript
npm run smoke         # 起一個真的 MCP client，跑過工具列表與三個唯讀工具
```

直接測橋接程式：

```bash
echo '{"command":"events","start":"2026-08-15","end":"2026-08-22"}' | ./bin/calendar-bridge
```

橋接程式的位置可以用 `CALENDAR_BRIDGE_PATH` 覆寫，Cowork 外掛的打包版就靠這個——claude.ai 的外掛驗證器不收頂層 `bin/` 目錄，所以那邊的二進位檔放在 `libexec/`。

#### 檔案

| 路徑 | 職責 |
| --- | --- |
| `src/swift/main.swift` | EventKit 橋接程式；所有行事曆操作都在這裡 |
| `src/swift/Info.plist` | 權限用途說明，會被 link 進二進位檔 |
| `src/bridge.ts` | spawn 橋接程式、處理 timeout 與錯誤碼 |
| `src/index.ts` | MCP server 與工具定義 |
| `src/format.ts` | 把事件排版成給模型讀的文字 |
| `skills/apple-calendar/` | 教 Claude 何時、如何使用這些工具的 skill |
| `scripts/build-swift.sh` | 編譯 + ad-hoc 簽章 |
