import { directions, key, rulesFor } from "./api";
import { t } from "./i18n";
import { useOps } from "./ops";
import { useConfirm } from "./ui";

// Block / unblock with the script's preview: the counts come from the same
// match the backend runs, so they equal what execution does.
export function useRuleActions() {
  const ops = useOps();
  const [dialog, confirm] = useConfirm();

  async function block(paths: string[], ask = true) {
    const group = directions(ops.rules, true);
    let full = 0, partial = 0, none = 0;
    for (const p of paths) {
      const d = group.get(key(p));
      if (d?.inbound && d.outbound) full++;
      else if (d) partial++;
      else none++;
    }
    const count = none * 2 + partial;
    if (!count) return ops.notify("info", t.confirm.nothingToBlock);
    const lines = [
      none && t.confirm.blockNew(none),
      full && t.confirm.blockFull(full),
      partial && t.confirm.blockPartial(partial),
    ].filter((l): l is string => !!l);
    if (ask && !(await confirm({ title: t.confirm.blockTitle(paths.length), lines, ok: t.confirm.blockOk(count) }))) return;
    await ops.apply("block", paths);
  }

  async function unblock(paths: string[], ask = true) {
    const matched = rulesFor(ops.rules, paths);
    if (!matched.length) return ops.notify("info", t.confirm.nothingToUnblock);
    const programs = new Set(matched.map((r) => key(r.program))).size;
    const legacy = matched.filter((r) => r.legacy).length;
    const lines = [t.confirm.unblockBody(programs), legacy && t.confirm.unblockLegacy(legacy)].filter(
      (l): l is string => !!l,
    );
    if (ask && !(await confirm({ title: t.confirm.unblockTitle(matched.length), lines, ok: t.confirm.unblockOk }))) return;
    await ops.apply("unblock", paths);
  }

  async function removeAll() {
    const count = ops.rules.filter((r) => !r.legacy).length;
    if (!count) return ops.notify("info", t.confirm.nothingToUnblock);
    if (!(await confirm({ title: t.confirm.allTitle, lines: [t.confirm.allBody(count)], ok: t.confirm.allOk }))) return;
    await ops.apply("unblock", null);
  }

  return { dialog, block, unblock, removeAll };
}
