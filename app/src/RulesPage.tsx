import {
  Badge,
  Button,
  Caption1,
  SearchBox,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableCellLayout,
  TableHeader,
  TableHeaderCell,
  TableRow,
  TableSelectionCell,
  Tooltip,
} from "@fluentui/react-components";
import {
  AppGenericRegular,
  ArrowSyncRegular,
  DeleteRegular,
  DocumentDismissRegular,
  OpenRegular,
  ShieldKeyholeRegular,
} from "@fluentui/react-icons";
import { memo, useMemo, useState } from "react";
import { useRuleActions } from "./actions";
import { api, fileName, key } from "./api";
import { t } from "./i18n";
import { useOps } from "./ops";
import { EmptyState, useSelection, useStable } from "./ui";

const COL = {
  program: { flex: "1 1 0", minWidth: "180px" },
  directions: { flex: "0 0 190px", gap: "4px" },
  source: { flex: "0 0 130px" },
  actions: { flex: "0 0 80px", justifyContent: "flex-end" },
};

type Program = { program: string; inbound: boolean; outbound: boolean; legacy: boolean; missing: boolean };

const ProgramRow = memo(function ProgramRow(p: {
  item: Program;
  selected: boolean;
  canChange: boolean;
  onToggle: (program: string) => void;
  onAction: (a: "reveal" | "remove", program: string) => void;
}) {
  const { item } = p;
  return (
    <TableRow className="row" appearance={p.selected ? "neutral" : "none"} aria-selected={p.selected} onClick={() => p.onToggle(item.program)}>
      <TableSelectionCell checked={p.selected} checkboxIndicator={{ "aria-label": t.common.select }} />
      <TableCell style={COL.program} title={item.program}>
        <TableCellLayout truncate media={<AppGenericRegular />} description={item.program}>
          {fileName(item.program)}
          {item.missing && (
            <Tooltip content={t.rules.orphanHint} relationship="description">
              <Badge appearance="tint" color="danger" size="small" icon={<DocumentDismissRegular />} className="inline-badge">
                {t.rules.orphan}
              </Badge>
            </Tooltip>
          )}
        </TableCellLayout>
      </TableCell>
      <TableCell style={COL.directions}>
        {item.inbound && <Badge appearance="outline" color="informative">{t.common.inbound}</Badge>}
        {item.outbound && <Badge appearance="outline" color="informative">{t.common.outbound}</Badge>}
      </TableCell>
      <TableCell style={COL.source}>
        {item.legacy ? (
          <Tooltip content={t.rules.legacyHint} relationship="description">
            <Badge appearance="tint" color="warning">
              {t.rules.legacy}
            </Badge>
          </Tooltip>
        ) : (
          <Caption1 className="muted">{t.rules.group}</Caption1>
        )}
      </TableCell>
      <TableCell style={COL.actions} onClick={(e) => e.stopPropagation()}>
        {!item.missing && (
          <Tooltip content={t.common.reveal} relationship="label">
            <Button appearance="subtle" icon={<OpenRegular />} onClick={() => p.onAction("reveal", item.program)} />
          </Tooltip>
        )}
        <Tooltip content={t.rules.remove} relationship="label">
          <Button appearance="subtle" icon={<DeleteRegular />} disabled={!p.canChange} onClick={() => p.onAction("remove", item.program)} />
        </Tooltip>
      </TableCell>
    </TableRow>
  );
});

export function RulesPage({ hidden }: { hidden: boolean }) {
  const ops = useOps();
  const actions = useRuleActions();
  const [filter, setFilter] = useState("");
  const [onlyOrphans, setOnlyOrphans] = useState(false);

  const programs = useMemo(() => {
    const map = new Map<string, Program>();
    for (const r of ops.rules) {
      const k = key(r.program);
      const p = map.get(k) ?? { program: r.program, inbound: false, outbound: false, legacy: false, missing: r.missing };
      if (r.inbound) p.inbound = true;
      else p.outbound = true;
      p.legacy ||= r.legacy;
      map.set(k, p);
    }
    return [...map.values()].sort((a, b) => key(a.program).localeCompare(key(b.program)));
  }, [ops.rules]);

  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return programs.filter((p) => (!onlyOrphans || p.missing) && (!q || key(p.program).includes(q)));
  }, [programs, filter, onlyOrphans]);
  const sel = useSelection(useMemo(() => shown.map((p) => p.program), [shown]));
  const picked = shown.filter((p) => sel.selected.has(p.program));
  // nothing selected: Remove applies to what the filter shows (e.g. a deleted folder's path)
  const targets = (picked.length ? picked : shown).map((p) => p.program);
  const canChange = ops.canChange && !ops.busy;
  const orphans = ops.rules.filter((r) => r.missing).length;

  const onAction = useStable((a: "reveal" | "remove", program: string) =>
    a === "reveal" ? api.reveal(program) : actions.unblock([program], false),
  );

  return (
    <section className="page" hidden={hidden}>
      {actions.dialog}
      <div className="toolbar">
        <Button icon={<ArrowSyncRegular />} onClick={ops.reloadRules} disabled={!!ops.busy}>
          {t.common.refresh}
        </Button>
        <SearchBox className="grow" placeholder={t.common.filter} value={filter} onChange={(_, d) => setFilter(d.value)} />
        <Switch label={t.rules.onlyOrphans} checked={onlyOrphans} onChange={(_, d) => setOnlyOrphans(d.checked)} />
        <Button icon={<DeleteRegular />} disabled={!canChange || !targets.length} onClick={() => actions.unblock(targets)}>
          {`${t.rules.remove} (${targets.length})`}
        </Button>
        <Button disabled={!canChange || !ops.rules.some((r) => !r.legacy)} onClick={actions.removeAll}>
          {t.rules.removeAll}
        </Button>
      </div>
      <div className="list">
        {!programs.length ? (
          <EmptyState icon={<ShieldKeyholeRegular />} title={t.rules.emptyTitle} body={t.rules.emptyBody} />
        ) : (
          <Table noNativeElements size="medium" className="table" aria-label={t.nav.rules}>
            <TableHeader className="thead">
              <TableRow>
                <TableSelectionCell checked={sel.headerState} onClick={sel.toggleShown} checkboxIndicator={{ "aria-label": t.common.selectAll }} />
                <TableHeaderCell style={COL.program}>{t.rules.colProgram}</TableHeaderCell>
                <TableHeaderCell style={COL.directions}>{t.rules.colDirections}</TableHeaderCell>
                <TableHeaderCell style={COL.source}>{t.rules.colSource}</TableHeaderCell>
                <TableHeaderCell style={COL.actions} aria-hidden />
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map((p) => (
                <ProgramRow
                  key={p.program}
                  item={p}
                  selected={sel.selected.has(p.program)}
                  canChange={canChange}
                  onToggle={sel.toggle}
                  onAction={onAction}
                />
              ))}
            </TableBody>
          </Table>
        )}
        {!!programs.length && !shown.length && <Caption1 className="muted no-match">{t.rules.noMatch}</Caption1>}
      </div>
      {!!programs.length && (
        <Caption1 className="muted footer">{t.rules.stats(ops.rules.length, programs.length, orphans)}</Caption1>
      )}
    </section>
  );
}
