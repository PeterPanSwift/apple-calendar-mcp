---
name: apple-calendar
description: 讀寫 macOS 本機「行事曆」App。當使用者提到看行程、今天／這週有什麼會、排會議、新增或修改活動、刪除活動、找空檔約時間、查某人某事在不在行事曆上，或講到 Apple 行事曆、本機行事曆、iCloud 行事曆時使用。也在使用者要把某件事「排進行事曆」「加到日曆」時使用。不要用在 Google Calendar 或 Outlook 行事曆上——那些有各自的 connector。
---

# Apple Calendar

透過 EventKit 直接操作 macOS 本機行事曆。重複性事件會展開成實際發生的每一場。

## 先看清楚再動手

- 動到既有事件前，先用 `list_events` 或 `search_events` 找出目標，確認只有一筆符合。同名事件很常見。
- **`delete_event` 不可復原**，執行前一定要把要刪的事件（標題＋時間）覆述給使用者確認。
- 建立事件前先確認要放進哪個行事曆。沒指定就用預設；使用者有多個帳號（iCloud／公司）時，主動問一句比猜對划算。

## 工具

| 工具 | 用途 |
| --- | --- |
| `list_calendars` | 列出所有行事曆、來源帳號、是否可寫入、預設行事曆 |
| `list_events` | 查某區間的事件（預設今天起 7 天） |
| `search_events` | 文字比對標題／地點／備註（預設前後各一年） |
| `get_event` | 單一事件完整資料：備註、與會者、提醒、重複規則 |
| `create_event` | 建立事件，可設地點、備註、URL、提醒、重複規則、忙碌狀態 |
| `update_event` | 只更新有傳入的欄位 |
| `delete_event` | 刪除事件（不可復原） |
| `find_free_time` | 在工作時段內找出足夠長度的空檔 |

## 日期

參數接受 `2026-08-15`、`2026-08-15T14:30`、或完整 ISO-8601。**沒有時區標示一律當本機時區**，所以通常直接寫本地時間就好，不要自己換算成 UTC。

使用者說「下週三」「月底前」時，先確認今天日期再換算，並把換算後的實際日期講出來讓對方能糾正。

## 重複性事件

`list_events` 對重複事件會同時回傳 `id` 與 `occurrenceStart`。要改動或刪除**單一場次**，兩個都要傳，並用 `span` 決定範圍：

- `span: "this"`（預設）— 只影響這一場
- `span: "future"` — 這一場與之後所有場次

使用者說「取消下週的週會」時預設是 `"this"`；說「以後都不用開了」才是 `"future"`。不確定就問。

建立重複事件：

```json
{
  "title": "週會",
  "start": "2026-08-17T10:00",
  "duration_minutes": 30,
  "recurrence": { "frequency": "weekly", "days_of_week": ["MO"], "count": 12 }
}
```

`update_event` 傳 `"recurrence": null` 可移除重複規則。

## 找空檔

`find_free_time` 把 busy／tentative 的事件視為佔用，忽略整天事件與標記為 free 的事件。預設工作時段 09:00–18:00、不含週末，可用參數調整。回報空檔時直接給幾個具體選項，不要把整串原始輸出貼給使用者。

## 已知限制（先講，不要試了才說）

- **無法新增與會者。** EventKit 的 `EKParticipant` 唯讀。讀取既有與會者與回覆狀態沒問題；要邀請人請把名單寫在備註，或請使用者用 Calendar.app 送邀請。
- **不支援提醒事項（Reminders）。** 那是另一組 entity 與權限。
- **清空欄位要傳空字串**（`"location": ""`），不是 `null`。

## 出錯時

- `bridge_missing` — 外掛缺 `bin/calendar-bridge`，請使用者重裝外掛。
- 權限被拒 — 到「系統設定 → 隱私權與安全性 → 行事曆」，把 Claude 打開，然後重開 Claude。權限綁在啟動 server 的 app 上。
