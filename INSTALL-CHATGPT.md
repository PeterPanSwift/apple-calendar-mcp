# 安裝到 ChatGPT 桌面版

下載最新版：[AppleCalendarMCP-0.1.0.pkg](https://github.com/PeterPanSwift/apple-calendar-mcp/releases/download/v0.1.0/AppleCalendarMCP-0.1.0.pkg)

`AppleCalendarMCP-<version>.pkg` 會把自帶版 Apple Calendar MCP 安裝到：

```text
/Library/Application Support/AppleCalendarMCP
```

安裝程式也會自動把 `apple-calendar` STDIO server 註冊到
`~/.codex/config.toml`。ChatGPT 桌面版、Codex CLI 與 IDE extension 共用這份設定。

## 系統需求

- macOS 13 或更新版本
- Apple Silicon 或 Intel Mac
- Node.js 18 或更新版本
- ChatGPT 桌面版

安裝器會尋找 Homebrew、MacPorts、Volta、nvm 與 fnm 常見位置中的 Node.js。

## 安裝

1. 雙擊 `AppleCalendarMCP-<version>.pkg` 並完成安裝。
2. 完全結束 ChatGPT（⌘Q）後重新開啟。
3. 在輸入框輸入 `/mcp` 或 `/app`，確認 `apple-calendar` 顯示為 Enabled。
4. 輸入：「請使用 apple-calendar 列出我所有的行事曆」。
5. macOS 第一次詢問行事曆權限時，允許 ChatGPT 存取。

若沒有跳出權限提示，前往「系統設定 → 隱私權與安全性 → 行事曆」，開啟 ChatGPT，
然後完全結束並重新開啟 ChatGPT。

## 安全與更新

- 安裝前若已有 `~/.codex/config.toml`，安裝器會建立帶時間戳的備份。
- 安裝器只替換 `[mcp_servers.apple-calendar]`，其他 MCP 與 Codex 設定會保留。
- 寫入類工具預設要求確認；讀取類工具可直接執行。
- 重新安裝新版 `.pkg` 即可更新程式及 MCP 設定。

目前建置產物若未使用 Developer ID Installer 憑證簽署，macOS 可能顯示開發者無法驗證。
正式對外發布前，建議使用 Developer ID Installer 簽署並進行 notarization。

## 建置安裝器

```bash
npm install
npm run build:installer
```

產物位於 `release/AppleCalendarMCP-<version>.pkg`。

若電腦已安裝 Developer ID Installer 憑證：

```bash
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" npm run build:installer
```
