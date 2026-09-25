import { Channel, invoke } from "@tauri-apps/api/core";

export type EnvInfo = { admin: boolean; helper: boolean; firewallRunning: boolean };
export type ExeFile = { name: string; path: string; size: number };
export type Scan = { files: ExeFile[]; unreadable: number; cancelled: boolean };
export type Item = { kind: "folder" | "exe" | "other"; file: ExeFile };
export type Rule = { program: string; inbound: boolean; legacy: boolean; enabled: boolean; missing: boolean };
export type Outcome = "created" | "skipped" | "enabled" | "removed" | "paused" | "resumed" | "failed";
export type OpResult = { program: string; inbound: boolean; legacy: boolean; enabled: boolean; outcome: Outcome; error: string | null };
export type Done = { cancelled: boolean; results: OpResult[] };
export type Progress = { done: number; total: number };
export type Target = { program: string; inbound: boolean; enabled?: boolean };
export type Request =
  | { op: "block"; targets: Target[] }
  | { op: "unblock"; targets: Target[] | null; legacy: boolean }
  | { op: "setEnabled"; targets: Target[]; enabled: boolean };

export const api = {
  envInfo: () => invoke<EnvInfo>("env_info"),
  scan: (dir: string) => invoke<Scan>("scan", { dir }),
  inspect: (paths: string[]) => invoke<Item[]>("inspect", { paths }),
  listRules: () => invoke<Rule[]>("list_rules"),
  apply: (req: Request, onProgress: (p: Progress) => void) => {
    const ch = new Channel<Progress>();
    ch.onmessage = onProgress;
    return invoke<Done>("apply", { req, onProgress: ch });
  },
  cancel: () => invoke<void>("cancel"),
  reveal: (path: string) => invoke<void>("reveal", { path }),
  readText: (path: string) => invoke<string>("read_text", { path }),
  writeText: (path: string, text: string) => invoke<void>("write_text", { path, text }),
};

export const iconUrl = (path: string) => `http://icon.localhost/${encodeURIComponent(path)}`;

export const key = (path: string) => path.toLowerCase();

export const fileName = (path: string) => path.slice(path.lastIndexOf("\\") + 1);

export type Direction = "both" | "out" | "in";

export function targets(paths: string[], dir: Direction = "both"): Target[] {
  return paths.flatMap((program) => [
    ...(dir !== "out" ? [{ program, inbound: true }] : []),
    ...(dir !== "in" ? [{ program, inbound: false }] : []),
  ]);
}

// Per program: which directions actively block, and whether any rule is paused.
export type Status = { inbound: boolean; outbound: boolean; paused: boolean };
export type State = "blocked" | "in" | "out" | "paused" | "allowed";

export function statuses(rules: Rule[]) {
  const map = new Map<string, Status>();
  for (const r of rules) {
    const s = map.get(key(r.program)) ?? { inbound: false, outbound: false, paused: false };
    if (!r.enabled) s.paused = true;
    else if (r.inbound) s.inbound = true;
    else s.outbound = true;
    map.set(key(r.program), s);
  }
  return map;
}

export function stateOf(s?: Status): State {
  if (!s) return "allowed";
  if (s.inbound && s.outbound) return "blocked";
  if (s.inbound) return "in";
  if (s.outbound) return "out";
  return "paused";
}

// Same match as the backend: a group rule for program + direction is skipped
// when enabled and re-enabled when paused; anything else is created.
export function blockPlan(rules: Rule[], paths: string[], dir: Direction) {
  const group = new Map(rules.filter((r) => !r.legacy).map((r) => [`${key(r.program)}|${r.inbound}`, r.enabled]));
  const plan = { ops: 0, none: 0, full: 0, partial: 0 };
  for (const p of paths) {
    const states = targets([p], dir).map((t) => group.get(`${key(p)}|${t.inbound}`));
    const fix = states.filter((s) => s !== true).length;
    plan.ops += fix;
    if (!fix) plan.full++;
    else if (states.every((s) => s === undefined)) plan.none++;
    else plan.partial++;
  }
  return plan;
}

// Rules an unblock or pause of these programs touches, legacy included.
export function rulesFor(rules: Rule[], paths: string[]) {
  const set = new Set(paths.map(key));
  return rules.filter((r) => set.has(key(r.program)));
}

// Requests that put back what an operation changed.
export function inverse(results: OpResult[]): Request[] {
  const of = (...o: Outcome[]) =>
    results.filter((r) => o.includes(r.outcome)).map((r) => ({ program: r.program, inbound: r.inbound, enabled: r.enabled }));
  const reqs: Request[] = [];
  const created = of("created");
  const enabled = of("enabled", "resumed");
  const paused = of("paused");
  const removed = of("removed");
  if (created.length) reqs.push({ op: "unblock", targets: created, legacy: false });
  if (enabled.length) reqs.push({ op: "setEnabled", targets: enabled, enabled: false });
  if (paused.length) reqs.push({ op: "setEnabled", targets: paused, enabled: true });
  if (removed.length) reqs.push({ op: "block", targets: removed });
  return reqs;
}
