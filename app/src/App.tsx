import { useEffect, useMemo, useRef, useState } from "react";
import {
  Shield,
  ShieldOff,
  FolderOpen,
  RefreshCw,
  Flame,
  Minus,
  Square,
  X,
  CheckCircle2,
  AlertTriangle,
  Search,
  Lock,
  Unlock,
  FileWarning,
  Trash2,
  ExternalLink,
} from "lucide-react";

type ExeFile = { name: string; path: string; size: number };
type LogEntry = { level: "info" | "ok" | "error"; msg: string; ts: number };

function formatBytes(b: number): string {
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`;
  if (b < 1024 * 1024 * 1024) return `${(b / 1024 / 1024).toFixed(1)} MB`;
  return `${(b / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export default function App() {
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [user, setUser] = useState<string>("");
  const [version, setVersion] = useState<string>("");
  const [folder, setFolder] = useState<string | null>(null);
  const [files, setFiles] = useState<ExeFile[]>([]);
  const [blocked, setBlocked] = useState<Record<string, boolean>>({});
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [filter, setFilter] = useState<string>("");
  const [scanning, setScanning] = useState(false);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const logRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    window.fb.getInfo().then((info) => {
      setIsAdmin(info.isAdmin);
      setUser(info.user);
      setVersion(info.version);
    });
    const offLog = window.fb.onLog((e) =>
      setLogs((l) => [...l.slice(-499), { ...e, ts: Date.now() }])
    );
    const offRule = window.fb.onRuleUpdate(({ path, blocked }) =>
      setBlocked((b) => ({ ...b, [path]: blocked }))
    );
    const offProg = window.fb.onProgress((p) => setProgress(p));
    return () => {
      offLog();
      offRule();
      offProg();
    };
  }, []);

  useEffect(() => {
    logRef.current?.scrollTo({ top: logRef.current.scrollHeight, behavior: "smooth" });
  }, [logs.length]);

  const filtered = useMemo(() => {
    const q = filter.trim().toLowerCase();
    if (!q) return files;
    return files.filter(
      (f) => f.name.toLowerCase().includes(q) || f.path.toLowerCase().includes(q)
    );
  }, [files, filter]);

  const stats = useMemo(() => {
    const total = files.length;
    const blockedCount = files.filter((f) => blocked[f.path]).length;
    return { total, blocked: blockedCount, free: total - blockedCount };
  }, [files, blocked]);

  async function pickAndScan() {
    const f = await window.fb.pickFolder();
    if (!f) return;
    setFolder(f);
    await scan(f);
  }

  async function scan(target?: string) {
    const dir = target ?? folder;
    if (!dir) return;
    setScanning(true);
    setSelected(new Set());
    setFiles([]);
    setBlocked({});
    try {
      const found = await window.fb.scanExe(dir);
      setFiles(found);
      if (found.length) {
        const status = await window.fb.rulesStatus(found.map((f) => f.path));
        setBlocked(status || {});
      }
    } catch (e) {
      setLogs((l) => [
        ...l,
        { level: "error", msg: `Scan failed: ${(e as Error).message}`, ts: Date.now() },
      ]);
    } finally {
      setScanning(false);
    }
  }

  function toggleAll(checked: boolean) {
    if (checked) setSelected(new Set(filtered.map((f) => f.path)));
    else setSelected(new Set());
  }

  function toggleOne(p: string) {
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(p)) n.delete(p);
      else n.add(p);
      return n;
    });
  }

  async function doBlock(targets: ExeFile[]) {
    if (!isAdmin) return;
    if (!targets.length) return;
    setBusy(true);
    setProgress({ done: 0, total: targets.length });
    try {
      await window.fb.block(targets.map((t) => ({ name: t.name, path: t.path })));
    } finally {
      setBusy(false);
      setTimeout(() => setProgress(null), 1500);
    }
  }

  async function doUnblock(targets: ExeFile[]) {
    if (!isAdmin) return;
    if (!targets.length) return;
    setBusy(true);
    setProgress({ done: 0, total: targets.length });
    try {
      await window.fb.unblock(targets.map((t) => ({ name: t.name, path: t.path })));
    } finally {
      setBusy(false);
      setTimeout(() => setProgress(null), 1500);
    }
  }

  const selectedFiles = files.filter((f) => selected.has(f.path));
  const allSelected = filtered.length > 0 && filtered.every((f) => selected.has(f.path));

  return (
    <div className="h-screen w-screen flex flex-col text-ink-100">
      {/* Titlebar */}
      <div className="titlebar-drag h-10 flex items-center justify-between px-4 border-b border-white/5 bg-ink-950/60">
        <div className="flex items-center gap-2">
          <div className="w-6 h-6 rounded-md bg-gradient-to-br from-flame-500 to-flame-600 flex items-center justify-center shadow-glow">
            <Flame size={14} className="text-white" />
          </div>
          <span className="text-sm font-semibold tracking-wide">Firewall Blocker</span>
          <span className="text-[10px] text-ink-400 ml-1">v{version || "2.0.0"}</span>
        </div>
        <div className="titlebar-nodrag flex items-center gap-1">
          <button
            onClick={() => window.fb.win.minimize()}
            className="w-9 h-7 grid place-items-center rounded hover:bg-white/5"
          >
            <Minus size={14} />
          </button>
          <button
            onClick={() => window.fb.win.maximize()}
            className="w-9 h-7 grid place-items-center rounded hover:bg-white/5"
          >
            <Square size={12} />
          </button>
          <button
            onClick={() => window.fb.win.close()}
            className="w-9 h-7 grid place-items-center rounded hover:bg-flame-600"
          >
            <X size={14} />
          </button>
        </div>
      </div>

      {/* Header */}
      <div className="px-6 pt-5 pb-3 flex items-end justify-between gap-4 border-b border-white/5">
        <div>
          <h1 className="text-xl font-bold">Block firewall rules for .exe files</h1>
          <p className="text-xs text-ink-300 mt-1">
            Pick a folder. We scan recursively and let you block or unblock matches via Windows Firewall.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <AdminBadge isAdmin={isAdmin} user={user} />
        </div>
      </div>

      {/* Toolbar */}
      <div className="px-6 py-3 flex flex-wrap items-center gap-2 border-b border-white/5 bg-ink-900/40">
        <button
          onClick={pickAndScan}
          className="inline-flex items-center gap-2 px-3 py-2 rounded-lg bg-flame-500 hover:bg-flame-400 text-white text-sm font-medium shadow-glow disabled:opacity-50"
          disabled={scanning || busy}
        >
          <FolderOpen size={15} />
          Select folder
        </button>
        <button
          onClick={() => scan()}
          disabled={!folder || scanning || busy}
          className="inline-flex items-center gap-2 px-3 py-2 rounded-lg bg-ink-700 hover:bg-ink-600 text-sm disabled:opacity-40"
        >
          <RefreshCw size={15} className={scanning ? "animate-spin" : ""} />
          Rescan
        </button>
        <div className="flex-1 min-w-[180px] flex items-center gap-2 px-3 py-2 rounded-lg bg-ink-800/80 border border-white/5">
          <Search size={14} className="text-ink-400" />
          <input
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            placeholder="Filter by name or path..."
            className="flex-1 bg-transparent outline-none text-sm placeholder:text-ink-400"
          />
        </div>
        <button
          onClick={() => doBlock(selectedFiles.length ? selectedFiles : files)}
          disabled={busy || !isAdmin || !files.length}
          className="inline-flex items-center gap-2 px-3 py-2 rounded-lg bg-rose-600 hover:bg-rose-500 text-white text-sm font-medium disabled:opacity-40"
          title={!isAdmin ? "Requires Administrator" : ""}
        >
          <Shield size={15} />
          Block {selectedFiles.length ? `(${selectedFiles.length})` : "all"}
        </button>
        <button
          onClick={() => doUnblock(selectedFiles.length ? selectedFiles : files)}
          disabled={busy || !isAdmin || !files.length}
          className="inline-flex items-center gap-2 px-3 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium disabled:opacity-40"
          title={!isAdmin ? "Requires Administrator" : ""}
        >
          <ShieldOff size={15} />
          Unblock {selectedFiles.length ? `(${selectedFiles.length})` : "all"}
        </button>
      </div>

      {/* Path bar / stats */}
      <div className="px-6 py-2 flex items-center justify-between gap-4 border-b border-white/5 bg-ink-900/20">
        <div className="text-xs text-ink-300 truncate">
          <span className="text-ink-400">Folder:</span>{" "}
          <span className="font-mono text-ink-200">{folder ?? "— none selected —"}</span>
        </div>
        <div className="flex items-center gap-3 text-xs">
          <Stat label="Total" value={stats.total} tone="neutral" />
          <Stat label="Blocked" value={stats.blocked} tone="bad" />
          <Stat label="Free" value={stats.free} tone="good" />
        </div>
      </div>

      {/* Content split */}
      <div className="flex-1 min-h-0 grid grid-cols-1 lg:grid-cols-[1fr_360px]">
        {/* File list */}
        <div className="min-h-0 flex flex-col">
          <div className="px-6 py-2 flex items-center gap-2 border-b border-white/5 bg-ink-900/30">
            <input
              type="checkbox"
              checked={allSelected}
              onChange={(e) => toggleAll(e.target.checked)}
              className="accent-flame-500"
            />
            <span className="text-xs text-ink-300">
              {filtered.length} shown · {selected.size} selected
            </span>
          </div>
          <div className="flex-1 min-h-0 overflow-auto">
            {scanning ? (
              <SkeletonList />
            ) : filtered.length === 0 ? (
              <EmptyState folder={folder} />
            ) : (
              <ul className="divide-y divide-white/5">
                {filtered.map((f) => {
                  const isBlocked = !!blocked[f.path];
                  const isSel = selected.has(f.path);
                  return (
                    <li
                      key={f.path}
                      className={`px-6 py-2.5 flex items-center gap-3 hover:bg-white/5 transition ${
                        isSel ? "bg-flame-500/5" : ""
                      }`}
                    >
                      <input
                        type="checkbox"
                        checked={isSel}
                        onChange={() => toggleOne(f.path)}
                        className="accent-flame-500"
                      />
                      <div className="w-7 h-7 rounded-md bg-ink-700 grid place-items-center text-ink-300">
                        <FileWarning size={14} />
                      </div>
                      <div className="flex-1 min-w-0">
                        <div className="text-sm font-medium truncate">{f.name}</div>
                        <div className="text-[11px] text-ink-400 font-mono truncate">
                          {f.path}
                        </div>
                      </div>
                      <span className="text-[11px] text-ink-400 font-mono">
                        {formatBytes(f.size)}
                      </span>
                      {isBlocked ? (
                        <span className="inline-flex items-center gap-1 text-[11px] px-2 py-1 rounded-md bg-rose-500/10 text-rose-300 border border-rose-500/20">
                          <Lock size={11} /> Blocked
                        </span>
                      ) : (
                        <span className="inline-flex items-center gap-1 text-[11px] px-2 py-1 rounded-md bg-emerald-500/10 text-emerald-300 border border-emerald-500/20">
                          <Unlock size={11} /> Allowed
                        </span>
                      )}
                      <div className="flex items-center gap-1">
                        <button
                          onClick={() => window.fb.reveal(f.path)}
                          className="w-7 h-7 grid place-items-center rounded hover:bg-white/10 text-ink-300"
                          title="Reveal in Explorer"
                        >
                          <ExternalLink size={13} />
                        </button>
                        {isBlocked ? (
                          <button
                            onClick={() => doUnblock([f])}
                            disabled={busy || !isAdmin}
                            className="w-7 h-7 grid place-items-center rounded hover:bg-emerald-500/20 text-emerald-300 disabled:opacity-40"
                            title="Unblock"
                          >
                            <ShieldOff size={13} />
                          </button>
                        ) : (
                          <button
                            onClick={() => doBlock([f])}
                            disabled={busy || !isAdmin}
                            className="w-7 h-7 grid place-items-center rounded hover:bg-rose-500/20 text-rose-300 disabled:opacity-40"
                            title="Block"
                          >
                            <Shield size={13} />
                          </button>
                        )}
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </div>

        {/* Console */}
        <aside className="border-l border-white/5 bg-ink-950/40 flex flex-col min-h-0">
          <div className="px-4 py-2 flex items-center justify-between border-b border-white/5">
            <div className="text-xs font-semibold text-ink-200 uppercase tracking-wider">
              Activity
            </div>
            <button
              onClick={() => setLogs([])}
              className="text-ink-400 hover:text-ink-100 text-xs inline-flex items-center gap-1"
            >
              <Trash2 size={12} /> Clear
            </button>
          </div>
          {progress && (
            <div className="px-4 pt-3">
              <div className="flex items-center justify-between text-[11px] text-ink-300 mb-1">
                <span>Processing</span>
                <span className="font-mono">
                  {progress.done}/{progress.total}
                </span>
              </div>
              <div className="h-1.5 rounded-full bg-ink-700 overflow-hidden">
                <div
                  className="h-full bg-gradient-to-r from-flame-500 to-flame-400 transition-all"
                  style={{
                    width: `${progress.total ? (progress.done / progress.total) * 100 : 0}%`,
                  }}
                />
              </div>
            </div>
          )}
          <div ref={logRef} className="flex-1 min-h-0 overflow-auto p-4 font-mono text-[11px] space-y-1">
            {logs.length === 0 ? (
              <div className="text-ink-400">No activity yet. Pick a folder to begin.</div>
            ) : (
              logs.map((l, i) => (
                <div key={i} className="flex gap-2">
                  <span className="text-ink-500">
                    {new Date(l.ts).toLocaleTimeString()}
                  </span>
                  <span
                    className={
                      l.level === "ok"
                        ? "text-emerald-300"
                        : l.level === "error"
                        ? "text-rose-300"
                        : "text-ink-200"
                    }
                  >
                    {l.msg}
                  </span>
                </div>
              ))
            )}
          </div>
          <div className="px-4 py-2 border-t border-white/5 text-[10px] text-ink-400">
            Rules created use the names <span className="font-mono">Block &lt;name&gt; Inbound/Outbound</span>.
          </div>
        </aside>
      </div>
    </div>
  );
}

function AdminBadge({ isAdmin, user }: { isAdmin: boolean | null; user: string }) {
  if (isAdmin === null) {
    return <div className="h-7 w-32 rounded-md shimmer" />;
  }
  return (
    <div
      className={`flex items-center gap-2 px-3 py-1.5 rounded-md text-xs border ${
        isAdmin
          ? "bg-emerald-500/10 border-emerald-500/30 text-emerald-300"
          : "bg-rose-500/10 border-rose-500/30 text-rose-300"
      }`}
    >
      {isAdmin ? <CheckCircle2 size={14} /> : <AlertTriangle size={14} />}
      {isAdmin ? "Administrator" : "NOT Admin"}
      <span className="text-ink-400 ml-1">· {user}</span>
    </div>
  );
}

function Stat({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone: "good" | "bad" | "neutral";
}) {
  const cls =
    tone === "good"
      ? "text-emerald-300"
      : tone === "bad"
      ? "text-rose-300"
      : "text-ink-200";
  return (
    <div className="flex items-center gap-1.5">
      <span className="text-ink-400">{label}:</span>
      <span className={`font-mono font-semibold ${cls}`}>{value}</span>
    </div>
  );
}

function SkeletonList() {
  return (
    <ul className="divide-y divide-white/5">
      {Array.from({ length: 8 }).map((_, i) => (
        <li key={i} className="px-6 py-3 flex items-center gap-3">
          <div className="w-4 h-4 rounded shimmer" />
          <div className="w-7 h-7 rounded-md shimmer" />
          <div className="flex-1 space-y-1.5">
            <div className="h-3 w-1/3 rounded shimmer" />
            <div className="h-2 w-2/3 rounded shimmer" />
          </div>
          <div className="h-5 w-16 rounded shimmer" />
        </li>
      ))}
    </ul>
  );
}

function EmptyState({ folder }: { folder: string | null }) {
  return (
    <div className="h-full grid place-items-center text-center px-6 py-16">
      <div className="max-w-md">
        <div className="w-14 h-14 rounded-2xl mx-auto bg-gradient-to-br from-flame-500/20 to-flame-600/10 grid place-items-center border border-flame-500/20">
          <Flame className="text-flame-400" />
        </div>
        <h3 className="mt-4 text-base font-semibold">
          {folder ? "No .exe files found" : "Pick a folder to scan"}
        </h3>
        <p className="mt-1 text-xs text-ink-400">
          {folder
            ? "The selected folder and its subdirectories contain no executables."
            : "Choose any directory — we walk it recursively and surface every .exe so you can block or unblock with one click."}
        </p>
      </div>
    </div>
  );
}
