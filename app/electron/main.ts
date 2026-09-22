import { app, BrowserWindow, ipcMain, dialog, shell } from "electron";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const isDev = !!process.env.VITE_DEV_SERVER_URL;

// Same rule engine as the PowerShell script, so both see the same rules.
const enginePath = app.isPackaged
  ? path.join(process.resourcesPath, "engine.ps1")
  : path.join(__dirname, "../../script/lib/engine.ps1");

let mainWindow: BrowserWindow | null = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 760,
    minWidth: 880,
    minHeight: 600,
    backgroundColor: "#070809",
    title: "Firewall Blocker",
    autoHideMenuBar: true,
    frame: false,
    titleBarStyle: "hidden",
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  mainWindow.once("ready-to-show", () => mainWindow?.show());

  if (isDev) {
    mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL!);
  } else {
    mainWindow.loadFile(path.join(__dirname, "../dist/index.html"));
  }

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });
}

app.whenReady().then(createWindow);
app.on("window-all-closed", () => app.quit());

// ---------- Window controls ----------
ipcMain.handle("win:minimize", () => mainWindow?.minimize());
ipcMain.handle("win:maximize", () => {
  if (!mainWindow) return;
  if (mainWindow.isMaximized()) mainWindow.unmaximize();
  else mainWindow.maximize();
});
ipcMain.handle("win:close", () => mainWindow?.close());

// ---------- Engine bridge ----------
type Status = "blocked" | "partial" | "none";
type EngineResult = { File: string; Name: string; Direction: string; Outcome: string; Detail: string };
type EngineLine = Record<string, any>;

function psQuote(s: string): string {
  return `'${s.replace(/'/g, "''")}'`;
}

// Runs `body` with the engine loaded, `input` as JSON on stdin, one JSON object
// per stdout line. The engine is loaded from text, so execution policy does not apply.
function runEngine(body: string, input: unknown, onLine?: (o: EngineLine) => void): Promise<EngineLine[]> {
  const script = [
    "$ErrorActionPreference = 'Stop'",
    "$ProgressPreference = 'SilentlyContinue'",
    `. ([scriptblock]::Create([IO.File]::ReadAllText(${psQuote(enginePath)})))`,
    "$req = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json",
    "$out = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object Text.UTF8Encoding $false))",
    "$out.AutoFlush = $true",
    "function Emit($o) { $out.WriteLine((ConvertTo-Json -InputObject $o -Compress -Depth 4)) }",
    body,
  ].join("\n");
  return new Promise((resolve, reject) => {
    const ps = spawn(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(script, "utf16le").toString("base64")],
      { windowsHide: true }
    );
    const lines: EngineLine[] = [];
    let buf = "";
    let err = "";
    ps.stdout.setEncoding("utf8");
    ps.stdout.on("data", (d: string) => {
      buf += d;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line) continue;
        let o: EngineLine;
        try {
          o = JSON.parse(line);
        } catch {
          err += line + "\n";
          continue;
        }
        lines.push(o);
        onLine?.(o);
      }
    });
    ps.stderr.on("data", (d) => (err += d.toString()));
    ps.on("error", reject);
    ps.on("close", (code) =>
      code === 0 ? resolve(lines) : reject(new Error(err.trim() || `PowerShell exited with code ${code}`))
    );
    ps.stdin.end(JSON.stringify(input ?? null));
  });
}

const PS_ADMIN = `Emit @{ admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }`;

const PS_STATUS = `
$dirs = Get-BlockedDirections
foreach ($p in @($req.paths)) {
  $d = $dirs[$p]
  if ($d -and $d.Inbound -and $d.Outbound) { $s = 'blocked' } elseif ($d) { $s = 'partial' } else { $s = 'none' }
  Emit @{ path = $p; status = $s }
}`;

const PS_PROGRESS = `{ param($op, $total, $r) Emit @{ op = $op; total = $total; result = $r } }`;

const PS_BLOCK = `
$files = @($req.files | ForEach-Object { [pscustomobject]@{ FullName = $_.path; Name = $_.name } })
$null = Invoke-BlockRules -Files $files -Existing (Get-FwbRules) -DryRun $false -OnProgress ${PS_PROGRESS}`;

const PS_UNBLOCK = `
$targets = @(Get-UnblockTargets -Scope Files -Files @($req.paths))
$null = Invoke-UnblockRules -Targets $targets -DryRun $false -OnProgress ${PS_PROGRESS}`;

// ---------- IPC: app info / picker / scan ----------
ipcMain.handle("app:info", async () => {
  const [info] = await runEngine(PS_ADMIN, null).catch(() => []);
  return {
    isAdmin: info?.admin === true,
    version: app.getVersion(),
    user: os.userInfo().username,
  };
});

ipcMain.handle("dialog:pickFolder", async () => {
  const r = await dialog.showOpenDialog(mainWindow!, {
    properties: ["openDirectory"],
    title: "Select a folder to scan",
  });
  if (r.canceled || r.filePaths.length === 0) return null;
  return r.filePaths[0];
});

ipcMain.handle("scan:exe", async (_e, dir: string) => {
  const stat = await fs.stat(dir).catch(() => null);
  if (!stat || !stat.isDirectory()) throw new Error("Invalid directory");
  const results: { name: string; path: string; size: number }[] = [];
  async function walk(p: string) {
    let entries;
    try {
      entries = await fs.readdir(p, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = path.join(p, e.name);
      if (e.isDirectory()) {
        await walk(full);
      } else if (e.isFile() && e.name.toLowerCase().endsWith(".exe")) {
        try {
          const s = await fs.stat(full);
          results.push({ name: e.name, path: full, size: s.size });
        } catch {}
      }
    }
  }
  await walk(dir);
  return results;
});

// Block state per exe path, legacy v1 rules included.
ipcMain.handle("rules:status", async (_e, paths: string[]) => {
  const status: Record<string, Status> = {};
  if (!paths.length) return status;
  for (const o of await runEngine(PS_STATUS, { paths })) status[o.path] = o.status;
  return status;
});

// ---------- Block / Unblock ----------
function send(channel: string, payload: unknown) {
  mainWindow?.webContents.send(channel, payload);
}

async function runAction(verb: "Block" | "Unblock", files: { name: string; path: string }[]) {
  if (!files.length) return;
  send("log", { level: "info", msg: `${verb}: ${files.length} file(s)...` });
  const counts: Record<string, number> = {};
  const body = verb === "Block" ? PS_BLOCK : PS_UNBLOCK;
  const input = verb === "Block" ? { files } : { paths: files.map((f) => f.path) };
  try {
    await runEngine(body, input, (o) => {
      const r = o.result as EngineResult;
      counts[r.Outcome] = (counts[r.Outcome] ?? 0) + 1;
      if (r.Outcome === "Failed") {
        send("log", { level: "error", msg: `${r.Name} (${r.Direction.toLowerCase()}): ${r.Detail}` });
      }
      send("progress", { done: o.op, total: o.total });
    });
  } catch (e) {
    counts.Failed = (counts.Failed ?? 0) + 1;
    send("log", { level: "error", msg: (e as Error).message });
  }
  const summary = Object.entries(counts)
    .map(([k, v]) => `${v} ${k.toLowerCase()}`)
    .join(", ");
  send("log", {
    level: counts.Failed ? "error" : "ok",
    msg: `${verb} done: ${summary || "no matching rules"}`,
  });
}

ipcMain.handle("action:block", (_e, files) => runAction("Block", files));
ipcMain.handle("action:unblock", (_e, files) => runAction("Unblock", files));

ipcMain.handle("shell:openPath", async (_e, p: string) => {
  shell.showItemInFolder(p);
});
