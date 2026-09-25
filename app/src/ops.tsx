import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { api, fileName, inverse, type EnvInfo, type OpResult, type Outcome, type Progress, type Request, type Rule, type Scan } from "./api";
import { num, t } from "./i18n";

export type LogEntry = { ts: number; level: "info" | "success" | "error"; msg: string };
export type Summary = {
  intent: "info" | "success" | "warning" | "error";
  title: string;
  body: string;
  failures: OpResult[];
  undo?: Request[];
};
export type Busy = { label: string; determinate: boolean };

// progress ticks skip React context so only the progress bar re-renders
export const progressBus = new EventTarget();

const secs = (start: number) => num((performance.now() - start) / 1000, 1);

export const failureText = (r: OpResult) =>
  `${fileName(r.program)} (${r.inbound ? t.common.inbound : t.common.outbound}): ${r.error}`;

const label = (req: Request) =>
  req.op === "setEnabled" ? (req.enabled ? t.op.resume : t.op.pause) : t.op[req.op];

// backend error codes worth a sentence of their own
const errorText = (e: unknown) =>
  e === "elevationCancelled" ? t.op.elevationCancelled : e === "helperFailed" ? t.op.helperFailed : String(e);

const counted: Outcome[] = ["created", "enabled", "removed", "paused", "resumed", "skipped"];

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
    setBusy({ label: t.op.scanning(dir), determinate: false });
    const start = performance.now();
    try {
      const s = await api.scan(dir);
      addLog("info", t.log.scanned(dir, s.files.length, secs(start)));
      if (s.unreadable) addLog("info", t.log.unreadable(s.unreadable));
      return s;
    } catch (e) {
      fail(e === "notFolder" ? t.programs.notFolder : t.op.failedToRun, e === "notFolder" ? dir : String(e));
      return null;
    } finally {
      setBusy(null);
    }
  }

  function report(req: Request, results: OpResult[], cancelled: boolean, total: number, s: string, undoable: boolean) {
    const failures = results.filter((r) => r.outcome === "failed");
    const parts = counted.map((o) => {
      const n = results.filter((r) => r.outcome === o).length;
      return n ? t.op[o](n) : "";
    });
    if (failures.length) parts.push(t.op.failed(failures.length));
    const title = cancelled ? t.op.cancelled(results.length, total) : failures.length ? t.op.doneErrors(s) : t.op.done(s);
    const body = parts.filter(Boolean).join(" · ");
    const intent = failures.length && failures.length === results.length ? "error" : failures.length || cancelled ? "warning" : "success";
    const undo = undoable ? inverse(results) : [];
    setSummary({ intent, title, body, failures, undo: undo.length ? undo : undefined });
    for (const f of failures) addLog("error", failureText(f));
    const level = intent === "error" ? "error" : intent === "success" ? "success" : "info";
    addLog(level, `${label(req)}: ${[body, title].filter(Boolean).join(" · ")}`);
  }

  // runs requests in order under one progress bar and one summary
  async function run(reqs: Request[], undoable: boolean) {
    let last: Progress = { done: 0, total: 0 };
    const tick = (p: Progress) => {
      last = p;
      progressBus.dispatchEvent(new CustomEvent("progress", { detail: p }));
    };
    setBusy({ label: label(reqs[0]), determinate: true });
    setSummary(null);
    tick(last);
    const start = performance.now();
    const results: OpResult[] = [];
    let cancelled = false;
    try {
      for (const req of reqs) {
        const done = await api.apply(req, tick);
        results.push(...done.results);
        if ((cancelled = done.cancelled)) break;
      }
      report(reqs[0], results, cancelled, last.total, secs(start), undoable);
    } catch (e) {
      if (results.length) report(reqs[0], results, true, last.total, secs(start), undoable);
      else fail(t.op.failedToRun, errorText(e));
    } finally {
      setBusy(null);
      await reloadRules();
      api.envInfo().then(setEnv);
    }
  }

  return {
    env,
    rules,
    busy,
    summary,
    log,
    canChange: !!env?.firewallRunning,
    reloadRules,
    scan,
    apply: (req: Request) => run([req], true),
    undo: () => summary?.undo && run(summary.undo, false),
    cancel: api.cancel,
    notify,
    fail,
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
