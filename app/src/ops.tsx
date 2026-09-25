import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { api, fileName, type Done, type EnvInfo, type OpResult, type Progress, type Rule, type Scan } from "./api";
import { num, t } from "./i18n";

export type LogEntry = { ts: number; level: "info" | "success" | "error"; msg: string };
export type Summary = { intent: "info" | "success" | "warning" | "error"; title: string; body: string; failures: OpResult[] };
export type Busy = { label: string; determinate: boolean };

// progress ticks skip React context so only the progress bar re-renders
export const progressBus = new EventTarget();

const secs = (start: number) => num((performance.now() - start) / 1000, 1);

export const failureText = (r: OpResult) =>
  `${fileName(r.program)} (${r.inbound ? t.common.inbound : t.common.outbound}): ${r.error}`;

function useOpsState() {
  const [env, setEnv] = useState<EnvInfo | null>(null);
  const [rules, setRules] = useState<Rule[]>([]);
  const [busy, setBusy] = useState<Busy | null>(null);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [log, setLog] = useState<LogEntry[]>([]);

  const addLog = (level: LogEntry["level"], msg: string) =>
    setLog((l) => [...l.slice(-499), { ts: Date.now(), level, msg }]);

  const notify = (intent: Summary["intent"], title: string, body = "") =>
    setSummary({ intent, title, body, failures: [] });

  const fail = (title: string, body: string) => {
    notify("error", title, body);
    addLog("error", `${title}: ${body}`);
  };

  async function reloadRules() {
    try {
      setRules(await api.listRules());
    } catch (e) {
      fail(t.op.failedToRun, String(e));
    }
  }

  useEffect(() => {
    api.envInfo().then(setEnv);
    reloadRules();
  }, []);

  async function scan(dir: string): Promise<Scan | null> {
    setBusy({ label: t.folder.scanning(dir), determinate: false });
    setSummary(null);
    const start = performance.now();
    try {
      const s = await api.scan(dir);
      addLog("info", t.log.scanned(dir, s.files.length, secs(start)));
      if (s.unreadable) addLog("info", t.log.unreadable(s.unreadable));
      return s;
    } catch (e) {
      fail(e === "notFolder" ? t.folder.notFolder : t.op.failedToRun, e === "notFolder" ? dir : String(e));
      return null;
    } finally {
      setBusy(null);
    }
  }

  function report(label: string, done: Done, last: Progress, s: string) {
    const count = (o: OpResult["outcome"]) => done.results.filter((r) => r.outcome === o).length;
    const failures = done.results.filter((r) => r.outcome === "failed");
    const parts = [
      count("created") && t.op.created(count("created")),
      count("removed") && t.op.removed(count("removed")),
      count("skipped") && t.op.skipped(count("skipped")),
      failures.length && t.op.failed(failures.length),
    ].filter(Boolean);
    const title = done.cancelled
      ? t.op.cancelled(done.results.length, last.total)
      : failures.length
        ? t.op.doneErrors(s)
        : t.op.done(s);
    const body = parts.join(" · ");
    const intent = failures.length && failures.length === done.results.length ? "error" : failures.length || done.cancelled ? "warning" : "success";
    setSummary({ intent, title, body, failures });
    for (const f of failures) addLog("error", failureText(f));
    const level = intent === "error" ? "error" : intent === "success" ? "success" : "info";
    addLog(level, `${label}: ${[body, title].filter(Boolean).join(" · ")}`);
  }

  async function apply(kind: "block" | "unblock", paths: string[] | null) {
    const label = kind === "block" ? t.op.blocking : t.op.unblocking;
    let last: Progress = { done: 0, total: 0 };
    const tick = (p: Progress) => {
      last = p;
      progressBus.dispatchEvent(new CustomEvent("progress", { detail: p }));
    };
    setBusy({ label, determinate: true });
    setSummary(null);
    tick(last);
    const start = performance.now();
    try {
      const done = kind === "block" ? await api.block(paths ?? [], tick) : await api.unblock(paths, tick);
      report(label, done, last, secs(start));
    } catch (e) {
      fail(t.op.failedToRun, String(e));
    } finally {
      setBusy(null);
      await reloadRules();
    }
  }

  return {
    env,
    rules,
    busy,
    summary,
    log,
    canChange: !!env?.admin && !!env?.firewallRunning,
    reloadRules,
    scan,
    apply,
    cancel: api.cancel,
    notify,
    dismissSummary: () => setSummary(null),
    clearLog: () => setLog([]),
  };
}

export type Ops = ReturnType<typeof useOpsState>;

const OpsContext = createContext<Ops | null>(null);

export function OpsProvider({ children }: { children: ReactNode }) {
  return <OpsContext.Provider value={useOpsState()}>{children}</OpsContext.Provider>;
}

export const useOps = () => useContext(OpsContext)!;
