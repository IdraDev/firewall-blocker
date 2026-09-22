import { app, BrowserWindow, ipcMain, dialog, shell } from "electron";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const isDev = !!process.env.VITE_DEV_SERVER_URL;

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
      sandbox: false,
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

app.whenReady().then(() => {
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

// ---------- Window controls ----------
ipcMain.handle("win:minimize", () => mainWindow?.minimize());
ipcMain.handle("win:maximize", () => {
  if (!mainWindow) return;
  if (mainWindow.isMaximized()) mainWindow.unmaximize();
  else mainWindow.maximize();
});
ipcMain.handle("win:close", () => mainWindow?.close());

// ---------- Helpers ----------
function isAdmin(): Promise<boolean> {
  return new Promise((resolve) => {
    const ps = spawn(
      "powershell.exe",
      [
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)",
      ],
      { windowsHide: true }
    );
    let out = "";
    ps.stdout.on("data", (d) => (out += d.toString()));
    ps.on("close", () => resolve(out.trim().toLowerCase() === "true"));
    ps.on("error", () => resolve(false));
  });
}

function runPSJson<T = unknown>(script: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const ps = spawn(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
      { windowsHide: true }
    );
    let out = "";
    let err = "";
    ps.stdout.on("data", (d) => (out += d.toString()));
    ps.stderr.on("data", (d) => (err += d.toString()));
    ps.on("close", (code) => {
      if (code !== 0) return reject(new Error(err || `PS exit ${code}`));
      const trimmed = out.trim();
      if (!trimmed) return resolve(null as T);
      try {
        resolve(JSON.parse(trimmed) as T);
      } catch (e) {
        reject(new Error(`JSON parse fail: ${(e as Error).message}\nOutput: ${trimmed.slice(0, 500)}`));
      }
    });
    ps.on("error", reject);
  });
}

function streamPS(
  script: string,
  onLine: (line: string, stream: "stdout" | "stderr") => void
): Promise<number> {
  return new Promise((resolve, reject) => {
    const ps = spawn(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
      { windowsHide: true }
    );
    let stdoutBuf = "";
    let stderrBuf = "";
    ps.stdout.on("data", (d) => {
      stdoutBuf += d.toString();
      let idx;
      while ((idx = stdoutBuf.indexOf("\n")) >= 0) {
        const line = stdoutBuf.slice(0, idx).replace(/\r$/, "");
        stdoutBuf = stdoutBuf.slice(idx + 1);
        if (line) onLine(line, "stdout");
      }
    });
    ps.stderr.on("data", (d) => {
      stderrBuf += d.toString();
      let idx;
      while ((idx = stderrBuf.indexOf("\n")) >= 0) {
        const line = stderrBuf.slice(0, idx).replace(/\r$/, "");
        stderrBuf = stderrBuf.slice(idx + 1);
        if (line) onLine(line, "stderr");
      }
    });
    ps.on("close", (code) => {
      if (stdoutBuf.trim()) onLine(stdoutBuf.trim(), "stdout");
      if (stderrBuf.trim()) onLine(stderrBuf.trim(), "stderr");
      resolve(code ?? 0);
    });
    ps.on("error", reject);
  });
}

function psEscape(s: string): string {
  return s.replace(/'/g, "''");
}

// ---------- IPC: app info / picker / scan ----------
ipcMain.handle("app:info", async () => {
  return {
    isAdmin: await isAdmin(),
    platform: process.platform,
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

// Return which exe paths already have block rules.
ipcMain.handle("rules:status", async (_e, paths: string[]) => {
  if (!paths.length) return {};
  const script = `
$ErrorActionPreference='SilentlyContinue'
$paths = @(${paths.map((p) => `'${psEscape(p)}'`).join(",")})
$result = @{}
$apps = Get-NetFirewallApplicationFilter | Select-Object Program,InstanceID
$rules = Get-NetFirewallRule -Action Block
$ruleMap = @{}
foreach ($r in $rules) { $ruleMap[$r.InstanceID] = $r }
foreach ($p in $paths) {
  $matches = $apps | Where-Object { $_.Program -ieq $p }
  $blocked = $false
  foreach ($m in $matches) {
    if ($ruleMap.ContainsKey($m.InstanceID)) { $blocked = $true; break }
  }
  $result[$p] = $blocked
}
$result | ConvertTo-Json -Compress
`;
  try {
    return await runPSJson<Record<string, boolean>>(script);
  } catch {
    return {} as Record<string, boolean>;
  }
});

// ---------- Block / Unblock streaming actions ----------
function send(channel: string, payload: unknown) {
  mainWindow?.webContents.send(channel, payload);
}

ipcMain.handle("action:block", async (_e, files: { name: string; path: string }[]) => {
  if (!files.length) return { ok: 0, fail: 0 };
  let ok = 0;
  let fail = 0;
  send("log", { level: "info", msg: `Starting BLOCK for ${files.length} file(s)...` });
  for (const f of files) {
    const safeName = psEscape(f.name);
    const safePath = psEscape(f.path);
    const script = `
$ErrorActionPreference='Stop'
try {
  $in  = Get-NetFirewallRule -DisplayName 'Block ${safeName} Inbound'  -ErrorAction SilentlyContinue
  $out = Get-NetFirewallRule -DisplayName 'Block ${safeName} Outbound' -ErrorAction SilentlyContinue
  if (-not $in)  { New-NetFirewallRule -DisplayName 'Block ${safeName} Inbound'  -Direction Inbound  -Program '${safePath}' -Action Block -Profile Any | Out-Null }
  if (-not $out) { New-NetFirewallRule -DisplayName 'Block ${safeName} Outbound' -Direction Outbound -Program '${safePath}' -Action Block -Profile Any | Out-Null }
  Write-Output 'OK'
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
`;
    const code = await streamPS(script, (line, stream) => {
      if (stream === "stderr") send("log", { level: "error", msg: `[${f.name}] ${line}` });
    });
    if (code === 0) {
      ok++;
      send("log", { level: "ok", msg: `Blocked ${f.name}` });
      send("rule:update", { path: f.path, blocked: true });
    } else {
      fail++;
      send("log", { level: "error", msg: `Failed to block ${f.name}` });
    }
    send("progress", { done: ok + fail, total: files.length });
  }
  send("log", { level: "info", msg: `Done. ${ok} ok, ${fail} fail.` });
  return { ok, fail };
});

ipcMain.handle("action:unblock", async (_e, files: { name: string; path: string }[]) => {
  if (!files.length) return { ok: 0, fail: 0 };
  let ok = 0;
  let fail = 0;
  send("log", { level: "info", msg: `Starting UNBLOCK for ${files.length} file(s)...` });
  for (const f of files) {
    const safeName = psEscape(f.name);
    const script = `
$ErrorActionPreference='SilentlyContinue'
Remove-NetFirewallRule -DisplayName 'Block ${safeName} Inbound'  | Out-Null
Remove-NetFirewallRule -DisplayName 'Block ${safeName} Outbound' | Out-Null
Write-Output 'OK'
`;
    const code = await streamPS(script, (line, stream) => {
      if (stream === "stderr") send("log", { level: "error", msg: `[${f.name}] ${line}` });
    });
    if (code === 0) {
      ok++;
      send("log", { level: "ok", msg: `Unblocked ${f.name}` });
      send("rule:update", { path: f.path, blocked: false });
    } else {
      fail++;
      send("log", { level: "error", msg: `Failed to unblock ${f.name}` });
    }
    send("progress", { done: ok + fail, total: files.length });
  }
  send("log", { level: "info", msg: `Done. ${ok} ok, ${fail} fail.` });
  return { ok, fail };
});

ipcMain.handle("shell:openPath", async (_e, p: string) => {
  await shell.showItemInFolder(p);
});
