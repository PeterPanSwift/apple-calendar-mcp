import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const here = path.dirname(fileURLToPath(import.meta.url));

/**
 * Where the Swift bridge lives.
 *
 * Defaults to `../bin/calendar-bridge` (the repo layout). `CALENDAR_BRIDGE_PATH`
 * overrides it — the Cowork plugin build needs this because claude.ai's plugin
 * validator rejects a top-level `bin/` directory, so the binary ships under
 * `libexec/` there instead.
 */
const BRIDGE = process.env.CALENDAR_BRIDGE_PATH
  ? path.resolve(process.env.CALENDAR_BRIDGE_PATH)
  : path.resolve(here, "..", "bin", "calendar-bridge");

/**
 * Restores the executable bit if packaging stripped it.
 *
 * Zip round-trips through some upload pipelines lose Unix permissions, which
 * turns into an opaque EACCES on first spawn. Cheap to repair, so try once and
 * let the spawn surface any real failure.
 */
function ensureExecutable(file: string): void {
  try {
    fs.accessSync(file, fs.constants.X_OK);
  } catch {
    try {
      fs.chmodSync(file, 0o755);
    } catch {
      /* read-only install; let the spawn error report it */
    }
  }
}

export class BridgeError extends Error {
  constructor(message: string, readonly code: string) {
    super(message);
  }
}

type BridgeResponse =
  | { ok: true; data: unknown }
  | { ok: false; error: string; code: string };

/** Runs one command through the EventKit bridge and returns its `data` payload. */
export async function callBridge(
  command: string,
  args: Record<string, unknown> = {},
  timeoutMs = 90_000,
): Promise<any> {
  if (!fs.existsSync(BRIDGE)) {
    throw new BridgeError(
      `calendar-bridge is missing at ${BRIDGE}. Run "npm run build:swift" to compile it.`,
      "bridge_missing",
    );
  }

  ensureExecutable(BRIDGE);

  const payload = JSON.stringify({ command, ...args });

  return new Promise((resolve, reject) => {
    const child = spawn(BRIDGE, [], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";

    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new BridgeError(`calendar-bridge timed out after ${timeoutMs}ms`, "timeout"));
    }, timeoutMs);

    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(new BridgeError(`could not run calendar-bridge: ${err.message}`, "spawn_failed"));
    });

    child.on("close", () => {
      clearTimeout(timer);
      let parsed: BridgeResponse;
      try {
        parsed = JSON.parse(stdout);
      } catch {
        const detail = stderr.trim() || stdout.trim() || "(no output)";
        reject(new BridgeError(`calendar-bridge returned unreadable output: ${detail}`, "bad_output"));
        return;
      }
      if (parsed.ok) resolve(parsed.data);
      else reject(new BridgeError(parsed.error, parsed.code));
    });

    child.stdin.end(payload);
  });
}
