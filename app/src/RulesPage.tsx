import {
  Badge,
  Button,
  Caption1,
  Menu,
  MenuDivider,
  MenuItem,
  MenuList,
  MenuPopover,
  MenuTrigger,
  SearchBox,
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
  ArrowDownloadRegular,
  ArrowSyncRegular,
  ArrowUploadRegular,
  DeleteRegular,
  DocumentDismissRegular,
  MoreHorizontalRegular,
  OpenRegular,
  PauseRegular,
  PlayRegular,
  ShieldKeyholeRegular,
} from "@fluentui/react-icons";
import { memo, useMemo, useState, type ReactElement } from "react";
import { useRuleActions } from "./actions";
import { api, fileName, key } from "./api";
import { t } from "./i18n";
import { useOps } from "./ops";
import { EmptyState, FilterBar, ProgramIcon, useSelection, useStable } from "./ui";

const COL = {
  program: { flex: "1 1 0", minWidth: "180px" },
  directions: { flex: "0 0 190px", gap: "4px" },
  source: { flex: "0 0 130px" },
  actions: { flex: "0 0 112px", justifyContent: "flex-end" },
};

type Program = { program: string; inbound: boolean; outbound: boolean; legacy: boolean; missing: boolean; active: number; paused: number };
type Group = "all" | "active" | "paused" | "orphans" | "legacy";
type RowAction = "reveal" | "remove" | "pause" | "resume";

const inGroup = (p: Program, g: Group) =>
  g === "all" || (g === "active" && p.active > 0) || (g === "paused" && p.paused > 0) || (g === "orphans" && p.missing) || (g === "legacy" && p.legacy);

const ProgramRow = memo(function ProgramRow(p: {
  item: Program;
  selected: boolean;
  canChange: boolean;
  onToggle: (program: string) => void;
  onAction: (a: RowAction, program: string) => void;
}) {
  const { item } = p;
  const button = (tip: string, icon: ReactElement, a: RowAction, gated = true) => (
    <Tooltip content={tip} relationship="label">
      <Button appearance="subtle" icon={icon} disabled={gated && !p.canChange} onClick={() => p.onAction(a, item.program)} />
    </Tooltip>
  );
  return (
    <TableRow className="row" appearance={p.selected ? "neutral" : "none"} aria-selected={p.selected} onClick={() => p.onToggle(item.program)}>
      <TableSelectionCell checked={p.selected} checkboxIndicator={{ "aria-label": t.common.select }} />
      <TableCell style={COL.program} title={item.program}>
        <TableCellLayout truncate media={<ProgramIcon path={item.program} />} description={item.program}>
          {fileName(item.program)}
          {item.missing && (
            <Tooltip content={t.rules.orphanHint} relationship="description">
              <Badge appearance="tint" color="danger" size="small" icon={<DocumentDismissRegular />} className="inline-badge">
                {t.rules.orphan}
              </Badge>
            </Tooltip>
          )}
          {!item.active && (
            <Badge appearance="tint" color="warning" size="small" icon={<PauseRegular />} className="inline-badge">
              {t.rules.isPaused}
            </Badge>
          )}
        </TableCellLayout>
      </TableCell>
      <TableCell style={COL.directions}>
        {item.inbound && (
          <Badge appearance="outline" color="informative">
            {t.common.inbound}
          </Badge>
        )}
        {item.outbound && (
          <Badge appearance="outline" color="informative">
            {t.common.outbound}
          </Badge>
        )}
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
      <TableCell style={COL.actions} className="row-actions" onClick={(e) => e.stopPropagation()}>
        {!item.missing && button(t.common.reveal, <OpenRegular />, "reveal", false)}
        {item.active ? button(t.common.pause, <PauseRegular />, "pause") : button(t.common.resume, <PlayRegular />, "resume")}
        {button(t.rules.remove, <DeleteRegular />, "remove")}
      </TableCell>
    </TableRow>
  );
});

export function RulesPage({ hidden }: { hidden: boolean }) {
  const ops = useOps();
  const actions = useRuleActions();
  const [filter, setFilter] = useState("");
  const [show, setShow] = useState<Group>("all");

  const programs = useMemo(() => {
    const map = new Map<string, Program>();
    for (const r of ops.rules) {
      const k = key(r.program);
      const p = map.get(k) ?? { program: r.program, inbound: false, outbound: false, legacy: false, missing: r.missing, active: 0, paused: 0 };
      if (r.inbound) p.inbound = true;
      else p.outbound = true;
      p.legacy ||= r.legacy;
      if (r.enabled) p.active++;
      else p.paused++;
      map.set(k, p);
    }
    return [...map.values()].sort((a, b) => key(a.program).localeCompare(key(b.program)));
  }, [ops.rules]);

  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return programs.filter((p) => inGroup(p, show) && (!q || key(p.program).includes(q)));
  }, [programs, filter, show]);
  const sel = useSelection(useMemo(() => shown.map((p) => p.program), [shown]));
  const picked = shown.filter((p) => sel.selected.has(p.program));
  // nothing selected: actions apply to what the filters show (e.g. a deleted folder's path)
  const targets = (picked.length ? picked : shown).map((p) => p.program);
  const canChange = ops.canChange && !ops.busy;

  const onAction = useStable((a: RowAction, program: string) => {
    if (a === "reveal") return api.reveal(program);
    if (a === "remove") return actions.unblock([program], false);
    return actions.setEnabled([program], a === "resume", false);
  });

  const groups: [Group, string][] = [
    ["all", t.rules.all],
    ["active", t.rules.active],
    ["paused", t.rules.paused],
    ["orphans", t.rules.orphans],
    ["legacy", t.rules.legacyFilter],
  ];
  return (
    <section className="page" hidden={hidden}>
      {actions.dialog}
      <div className="toolbar">
        <Tooltip content={t.common.refresh} relationship="label">
          <Button icon={<ArrowSyncRegular />} onClick={ops.reloadRules} disabled={!!ops.busy} />
        </Tooltip>
        <SearchBox className="grow" placeholder={t.common.filter} value={filter} onChange={(_, d) => setFilter(d.value)} />
        <Button icon={<DeleteRegular />} disabled={!canChange || !targets.length} onClick={() => actions.unblock(targets)}>
          {`${t.rules.remove} (${targets.length})`}
        </Button>
        <Menu>
          <MenuTrigger disableButtonEnhancement>
            <Tooltip content={t.common.more} relationship="label">
              <Button icon={<MoreHorizontalRegular />} disabled={!!ops.busy} />
            </Tooltip>
          </MenuTrigger>
          <MenuPopover>
            <MenuList>
              <MenuItem icon={<PauseRegular />} disabled={!canChange || !targets.length} onClick={() => actions.setEnabled(targets, false)}>
                {`${t.common.pause} (${targets.length})`}
              </MenuItem>
              <MenuItem icon={<PlayRegular />} disabled={!canChange || !targets.length} onClick={() => actions.setEnabled(targets, true)}>
                {`${t.common.resume} (${targets.length})`}
              </MenuItem>
              <MenuDivider />
              <MenuItem icon={<ArrowUploadRegular />} disabled={!programs.length} onClick={actions.exportRules}>
                {t.rules.export}
              </MenuItem>
              <MenuItem icon={<ArrowDownloadRegular />} disabled={!canChange} onClick={actions.importRules}>
                {t.rules.import}
              </MenuItem>
              <MenuDivider />
              <MenuItem icon={<DeleteRegular />} disabled={!canChange || !ops.rules.some((r) => !r.legacy)} onClick={actions.removeAll}>
                {t.rules.removeAll}
              </MenuItem>
            </MenuList>
          </MenuPopover>
        </Menu>
      </div>
      {!!programs.length && (
        <FilterBar
          value={show}
          onChange={setShow}
          options={groups.map(([value, label]) => ({ value, label, count: programs.filter((p) => inGroup(p, value)).length }))}
        />
      )}
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
        {!!programs.length && !shown.length && <p className="muted no-match">{t.rules.noMatch}</p>}
      </div>
    </section>
  );
}
