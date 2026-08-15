# 安裝到 Claude Cowork

自帶版：`dist/index.js` 已用 esbuild 打包成單一檔案（sdk 與 zod 都編進去了），
加上 `libexec/calendar-bridge` 這支 Swift 橋接程式。**外掛裡沒有 `node_modules`**，
不依賴原始專案資料夾 —— 裝完就算把 `~/Documents/VibeCoding/Apple Calendar MCP Server`
刪掉也照跑。

```
apple-calendar/
├── .claude-plugin/plugin.json
├── .mcp.json                      # 指向 dist/，並用環境變數告知橋接程式位置
├── dist/index.js                  # 打包後的 MCP server（單檔，198 KB）
├── libexec/calendar-bridge        # Swift + EventKit 橋接程式
├── skills/apple-calendar/SKILL.md # 教 Claude 怎麼用這些工具
└── package.json
```

---

## ⚠️ 先看這一段：Cowork 的工作要跑在「你的電腦上」

Cowork 有兩種執行位置，開新工作時右上角的 **「Run this task」** 可以選：

| 執行位置 | 本機 MCP server |
| --- | --- |
| **On your computer** | ✅ 可用 |
| **In the cloud** | ❌ 不可用 |

Anthropic 的架構說明寫得很直白：**「Local MCP servers don't run in sessions in the cloud.」**
雲端 session 只能透過桌面 App 借用你電腦的檔案與瀏覽器，不會幫你啟動本機 MCP server。

而這個外掛非跑在 macOS 主機上不可 —— EventKit 是 macOS API，Cowork 的 shell 是隔離的
Linux VM，Swift 橋接程式在裡面根本不能執行。所以：

> **開新 Cowork 工作時，一定要選「On your computer」。**
> 想設成預設值：Settings → Cowork → 把「Run new tasks in the cloud」關掉。

---

## 1. 安裝外掛

聊天裡的 `.plugin` 卡片直接按安裝鈕即可。或手動安裝：

1. 打開 Claude 桌面版，切到 **Cowork** 分頁
2. 左側邊欄 → **Customize**
3. 開 **Plugins** 分頁
4. 選上傳自訂外掛檔，挑 `apple-calendar.plugin`

裝完**完全結束 Claude（⌘Q）再重開**。

---

## 2. 開啟行事曆權限

macOS 的權限是綁在**啟動 server 的那個 app** 上，也就是 Claude 桌面版本身。

第一次叫用行事曆工具時，macOS 應該會跳出授權對話框，按「允許」。

沒跳出來、或不小心按了拒絕：

**系統設定 → 隱私權與安全性 → 行事曆 → 把 Claude 打開 → 完全結束 Claude 再重開**

---

## 3. 驗證

開一個 Cowork 工作（記得選 On your computer），問：

```
列出我所有的行事曆
```

會看到行事曆名稱、來源帳號、哪些可寫入。再試：

```
我這週有什麼行程？
```

---

## 排錯

**工具完全沒出現**
外掛沒裝成功，或工作跑在雲端。先確認右上角執行位置是「On your computer」，
再到 Customize → Plugins 確認 apple-calendar 是啟用狀態。裝完一定要重開 Claude。

**`bridge_missing`**
外掛裡缺 `bin/calendar-bridge`，重新打包安裝。

**`spawn_failed` 或 Gatekeeper 擋下來**
執行權限掉了的話 server 會自己 `chmod` 補回來，但隔離屬性要手動清。在終端機跑：

```bash
BRIDGE=$(find ~/.claude -name calendar-bridge -type f 2>/dev/null | head -1)
xattr -dr com.apple.quarantine "$BRIDGE"
chmod +x "$BRIDGE"
```

**權限一直被拒**
確認你在系統設定裡打開的是 **Claude**，不是 Terminal 或 VS Code。
權限跟著呼叫端的 app 走，換 client 就要重新授權一次。

**只讀得到部分行事曆**
macOS 15 之後可以只授權部分行事曆。到系統設定 → 隱私權與安全性 → 行事曆 改成完整存取。

---

## 打包時踩過的兩個驗證規則

**1. 路徑不能有 `@`**

第一版直接把 `node_modules` 整包塞進去，安裝時被擋下來：

> Zip file contains path with invalid characters

原因是 npm 的 scoped package 目錄名有 `@` —— `node_modules/@modelcontextprotocol/...`，
外掛安裝器的路徑檢查不收這個字元。改用 esbuild 把整棵相依樹編成一支
`dist/index.js` 之後，壓縮檔裡就只剩下 `[A-Za-z0-9._/-]`，順帶從 4.6 MB 縮到 198 KB。

**2. 不能有頂層 `bin/` 目錄**

> Plugin contains a top-level bin/ directory. claude.ai-hosted plugins may not
> ship bin/ executables because they are added to PATH on the CLI but are not
> shown on the admin approval surface.

`bin/` 會被 CLI 自動加進 PATH，但管理員審核介面看不到裡面有什麼，所以直接禁掉。
橋接程式改放 `libexec/`，位置透過 `.mcp.json` 的環境變數告訴 server：

```json
"env": {
  "CALENDAR_BRIDGE_PATH": "${CLAUDE_PLUGIN_ROOT}/libexec/calendar-bridge"
}
```

`src/bridge.ts` 已配合改成讀這個環境變數，沒設就沿用原本的 `../bin/calendar-bridge`，
所以專案裡的開發流程完全不受影響。同時加了一段保險：若橋接程式的執行權限在
壓縮往返中掉了，第一次呼叫時會自動 `chmod 755` 補回來。

---

## 更新外掛

外掛裡的程式碼是打包當下的快照。改完程式要重新打包：

```bash
cd ~/Documents/VibeCoding/"Apple Calendar MCP Server"
npm run build                       # 重建 bin/calendar-bridge 與 dist/

mkdir -p /tmp/ac/dist /tmp/ac/libexec
npx esbuild src/index.ts \
  --bundle --platform=node --format=esm --target=node18 \
  --outfile=/tmp/ac/dist/index.js \
  --banner:js='import { createRequire as __cr } from "node:module";
import { fileURLToPath as __f2p } from "node:url";
import { dirname as __dn } from "node:path";
const require = __cr(import.meta.url);
const __filename = __f2p(import.meta.url);
const __dirname = __dn(__filename);'

cp bin/calendar-bridge /tmp/ac/libexec/
chmod 755 /tmp/ac/libexec/calendar-bridge
# 再把 .claude-plugin/、.mcp.json、package.json、skills/ 複製進 /tmp/ac
cd /tmp/ac && zip -r /tmp/apple-calendar.plugin . -x "*.DS_Store"
```

到 Customize → Plugins 重裝。

**兩條紅線：不要放 `node_modules`（`@` 會被擋），不要有頂層 `bin/`。**

---

## 順便：Claude Code 也能用

專案根目錄的 `.mcp.json` 已經修成正確格式（外面要包一層 `mcpServers`）。
在專案目錄開 Claude Code 就會自動載入。或全域註冊：

```bash
claude mcp add apple-calendar -- node "/Users/shih-yingpan/Documents/VibeCoding/Apple Calendar MCP Server/dist/index.js"
```

這條路走的是 `tsc` 編出來的 `dist/`＋專案的 `node_modules`，跟外掛裡的打包版互不干擾。
注意這樣是 Terminal 啟動 server，所以行事曆權限要授權給 **Terminal**（或你的 IDE），不是 Claude。
