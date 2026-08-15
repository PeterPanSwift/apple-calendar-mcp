import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = "/Users/shih-yingpan/Documents/VibeCoding/Apple Calendar MCP Server";
const transport = new StdioClientTransport({ command: "node", args: [`${root}/dist/index.js`] });
const client = new Client({ name: "smoke", version: "1.0.0" });
await client.connect(transport);

const { tools } = await client.listTools();
console.log("tools:", tools.map((t) => t.name).join(", "));
console.log("\nlist_events schema keys:", Object.keys(tools.find(t => t.name === "list_events").inputSchema.properties).join(", "));

for (const call of [
  { name: "list_calendars", arguments: {} },
  { name: "list_events", arguments: { days: 3 } },
  { name: "find_free_time", arguments: { duration_minutes: 45, days: 3 } },
]) {
  const res = await client.callTool(call);
  console.log(`\n--- ${call.name} (isError=${!!res.isError}) ---`);
  console.log(res.content[0].text.slice(0, 600));
}

await client.close();
