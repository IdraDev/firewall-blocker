import { Channel, invoke } from "@tauri-apps/api/core";

export type EnvInfo = { admin: boolean; firewallRunning: boolean };
export type ExeFile = { name: string; path: string; size: number };
export type Scan = { files: ExeFile[]; unreadable: number; cancelled: boolean };
export type Rule = { program: string; inbound: boolean; legacy: boolean; missing: boolean };
export type Outcome = "created" | "skipped" | "removed" | "failed";
export type OpResult = { program: string; inbound: boolean; legacy: boolean; outcome: Outcome; error: string | null };
export type Done = { cancelled: boolean; results: OpResult[] };
export type Progress = { done: number; total: number };

function channel(onProgress: (p: Progress) => void) {
  const ch = new Channel<Progress>();
  ch.onmessage = onProgress;
  return ch;
}

export const api = {
  envInfo: () => invoke<EnvInfo>("env_info"),
  scan: (dir: string) => invoke<Scan>("scan", { dir }),
  listRules: () => invoke<Rule[]>("list_rules"),
  block: (paths: string[], onProgress: (p: Progress) => void) =>
    invoke<Done>("block", { paths, onProgress: channel(onProgress) }),
  // null = every FirewallBlocker rule (legacy v1 excluded)
  unblock: (paths: string[] | null, onProgress: (p: Progress) => void) =>
    invoke<Done>("unblock", { paths, onProgress: channel(onProgress) }),
  cancel: () => invoke<void>("cancel"),
  reveal: (path: string) => invoke<void>("reveal", { path }),
};

export const key = (path: string) => path.toLowerCase();

export const fileName = (path: string) => path.slice(path.lastIndexOf("\\") + 1);

export type Directions = { inbound: boolean; outbound: boolean };

// Blocked directions per program. The block plan passes groupOnly, like the
// backend: legacy rules count as blocked but never as "already exists".
export function directions(rules: Rule[], groupOnly = false) {
  const map = new Map<string, Directions>();
  for (const r of rules) {
    if (groupOnly && r.legacy) continue;
    const d = map.get(key(r.program)) ?? { inbound: false, outbound: false };
    if (r.inbound) d.inbound = true;
    else d.outbound = true;
    map.set(key(r.program), d);
  }
  return map;
}

// Rules an unblock of these programs removes, legacy included (same match as the backend).
export function rulesFor(rules: Rule[], paths: string[]) {
  const set = new Set(paths.map(key));
  return rules.filter((r) => set.has(key(r.program)));
}
