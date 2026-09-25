import { open, save } from "@tauri-apps/plugin-dialog";
import { api, blockPlan, key, rulesFor, targets, type Direction, type Target } from "./api";
import { t } from "./i18n";
import { useOps } from "./ops";
import { useConfirm } from "./ui";

const lines = (...l: (string | false | 0)[]) => l.filter((x): x is string => !!x);

type Export = { app: "Firewall Blocker"; version: 1; rules: Target[] };

// Every rule change goes through here: preview counts come from the same
// match the backend runs, so they equal what execution does.
export function useRuleActions() {
  const ops = useOps();
  const { dialog, confirm, ask } = useConfirm();

  async function block(paths: string[], confirmIt = true) {
    if (!blockPlan(ops.rules, paths, "both").ops) return ops.notify("info", t.confirm.nothingToBlock);
    let dir: Direction | null = "both";
    if (confirmIt) {
      dir = await confirm<Direction>({
        title: t.confirm.blockTitle(paths.length),
        initial: "both",
        choices: [
          { value: "both", label: t.confirm.both },
          { value: "out", label: t.confirm.outOnly },
          { value: "in", label: t.confirm.inOnly },
        ],
        lines: (d) => {
          const p = blockPlan(ops.rules, paths, d);
          return lines(p.none && t.confirm.blockNew(p.none), p.full && t.confirm.blockFull(p.full), p.partial && t.confirm.blockPartial(p.partial));
        },
        ok: (d) => t.confirm.blockOk(blockPlan(ops.rules, paths, d).ops),
        enabled: (d) => blockPlan(ops.rules, paths, d).ops > 0,
      });
    }
    if (dir) await ops.apply({ op: "block", targets: targets(paths, dir) });
  }

  async function unblock(paths: string[], confirmIt = true) {
    const hit = rulesFor(ops.rules, paths);
    if (!hit.length) return ops.notify("info", t.confirm.nothingToChange);
    const programs = new Set(hit.map((r) => key(r.program))).size;
    const legacy = hit.filter((r) => r.legacy).length;
    const body = lines(t.confirm.unblockBody(programs), legacy && t.confirm.unblockLegacy(legacy));
    if (confirmIt && !(await ask(t.confirm.unblockTitle(hit.length), body, t.confirm.unblockOk))) return;
    await ops.apply({ op: "unblock", targets: targets(paths), legacy: true });
  }

  async function setEnabled(paths: string[], enabled: boolean, confirmIt = true) {
    const hit = rulesFor(ops.rules, paths).filter((r) => r.enabled !== enabled);
    if (!hit.length) return ops.notify("info", t.confirm.nothingToChange);
    const [title, body, ok] = enabled
      ? [t.confirm.resumeTitle(hit.length), t.confirm.resumeBody, t.common.resume]
      : [t.confirm.pauseTitle(hit.length), t.confirm.pauseBody, t.common.pause];
    if (confirmIt && !(await ask(title, [body], ok))) return;
    await ops.apply({ op: "setEnabled", targets: targets(paths), enabled });
  }

  async function removeAll() {
    const count = ops.rules.filter((r) => !r.legacy).length;
    if (!count) return ops.notify("info", t.confirm.nothingToChange);
    if (!(await ask(t.confirm.allTitle, [t.confirm.allBody(count)], t.confirm.allOk))) return;
    await ops.apply({ op: "unblock", targets: null, legacy: false });
  }

  const filters = [{ name: t.rules.fileFilter, extensions: ["json"] }];

  async function exportRules() {
    const path = await save({ defaultPath: "firewall-blocker-rules.json", filters });
    if (!path) return;
    const rules = ops.rules.map(({ program, inbound, enabled }) => ({ program, inbound, enabled }));
    const data: Export = { app: "Firewall Blocker", version: 1, rules };
    try {
      await api.writeText(path, JSON.stringify(data, null, 2));
      ops.notify("success", t.rules.exported(rules.length, path));
    } catch (e) {
      ops.fail(t.op.failedToRun, String(e));
    }
  }

  async function importRules() {
    const path = await open({ filters });
    if (typeof path !== "string") return;
    let rules: Target[];
    try {
      const data = JSON.parse(await api.readText(path)) as Partial<Export>;
      if (data.app !== "Firewall Blocker" || !Array.isArray(data.rules)) throw 0;
      rules = data.rules.filter((r) => typeof r?.program === "string" && typeof r?.inbound === "boolean");
    } catch {
      return ops.notify("error", t.rules.badImport, path);
    }
    const programs = new Set(rules.map((r) => key(r.program))).size;
    if (!(await ask(t.confirm.importTitle(rules.length), [t.confirm.importBody(programs)], t.confirm.importOk))) return;
    await ops.apply({ op: "block", targets: rules.map((r) => ({ ...r, enabled: r.enabled !== false })) });
  }

  return { dialog, block, unblock, setEnabled, removeAll, exportRules, importRules };
}
