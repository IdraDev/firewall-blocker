import {
  Badge,
  Button,
  Menu,
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
  Tag,
  TagGroup,
  Tooltip,
} from "@fluentui/react-components";
import {
  AddRegular,
  AppsAddInRegular,
  ArrowSyncRegular,
  FolderAddRegular,
  FolderRegular,
  MoreHorizontalRegular,
  OpenRegular,
  PauseRegular,
  PlayRegular,
  ShieldCheckmarkRegular,
  ShieldDismissRegular,
} from "@fluentui/react-icons";
import { memo, useMemo, useState, type ReactElement } from "react";
import { useRuleActions } from "./actions";
import { api, fileName, key, stateOf, statuses, type State, type Status } from "./api";
import { DropHome } from "./DropHome";
import { bytes, t } from "./i18n";
import { useOps } from "./ops";
import type { Entry, Sources } from "./sources";
import { FilterBar, ProgramIcon, useSelection, useStable } from "./ui";

const COL = {
  name: { flex: "1 1 0", minWidth: "180px" },
  size: { flex: "0 0 112px", justifyContent: "flex-end", paddingRight: "24px" },
  status: { flex: "0 0 150px" },
  actions: { flex: "0 0 140px", justifyContent: "flex-end" },
};

type Group = "all" | "blocked" | "partial" | "paused" | "allowed";
type RowAction = "reveal" | "block" | "unblock" | "pause" | "resume";

const group = (s: State): Group => (s === "in" || s === "out" ? "partial" : s);

const badges: Record<State, ReactElement> = {
  blocked: (
    <Badge appearance="tint" color="informative" icon={<ShieldDismissRegular />}>
      {t.programs.isBlocked}
    </Badge>
  ),
  in: (
    <Badge appearance="outline" color="informative" icon={<ShieldDismissRegular />}>
      {t.programs.inOnly}
    </Badge>
  ),
  out: (
    <Badge appearance="outline" color="informative" icon={<ShieldDismissRegular />}>
      {t.programs.outOnly}
    </Badge>
  ),
  paused: (
    <Badge appearance="tint" color="warning" icon={<PauseRegular />}>
      {t.programs.isPaused}
    </Badge>
  ),
  allowed: (
    <Badge appearance="ghost" color="informative">
      {t.programs.isAllowed}
    </Badge>
  ),
};

// folder sources show the subfolder, single programs their full folder
function where(f: Entry) {
  const dir = f.path.slice(0, -f.name.length - 1);
  if (f.source.kind === "exe") return dir;
  return dir.slice(f.source.path.replace(/\\$/, "").length) || "\\";
}

function RowButton(p: { tip: string; icon: ReactElement; disabled?: boolean; onClick: () => void }) {
  return (
    <Tooltip content={p.tip} relationship="label">
      <Button appearance="subtle" icon={p.icon} disabled={p.disabled} onClick={p.onClick} />
    </Tooltip>
  );
}

const FileRow = memo(function FileRow(p: {
  file: Entry;
  s?: Status;
  selected: boolean;
  canChange: boolean;
  onToggle: (path: string) => void;
  onAction: (a: RowAction, path: string) => void;
}) {
  const { file, s } = p;
  const state = stateOf(s);
  const act = (a: RowAction) => () => p.onAction(a, file.path);
  return (
    <TableRow className="row" appearance={p.selected ? "neutral" : "none"} aria-selected={p.selected} onClick={() => p.onToggle(file.path)}>
      <TableSelectionCell checked={p.selected} checkboxIndicator={{ "aria-label": t.common.select }} />
      <TableCell style={COL.name} title={file.path}>
        <TableCellLayout truncate media={<ProgramIcon path={file.path} />} description={where(file)}>
          {file.name}
        </TableCellLayout>
      </TableCell>
      <TableCell style={COL.size} className="num muted">
        {bytes(file.size)}
      </TableCell>
      <TableCell style={COL.status}>{badges[state]}</TableCell>
      <TableCell style={COL.actions} className="row-actions" onClick={(e) => e.stopPropagation()}>
        <RowButton tip={t.common.reveal} icon={<OpenRegular />} onClick={act("reveal")} />
        {s && (s.inbound || s.outbound) && <RowButton tip={t.common.pause} icon={<PauseRegular />} disabled={!p.canChange} onClick={act("pause")} />}
        {state === "paused" && <RowButton tip={t.common.resume} icon={<PlayRegular />} disabled={!p.canChange} onClick={act("resume")} />}
        {state !== "blocked" && state !== "paused" && (
          <RowButton tip={t.common.block} icon={<ShieldDismissRegular />} disabled={!p.canChange} onClick={act("block")} />
        )}
        {s && <RowButton tip={t.common.unblock} icon={<ShieldCheckmarkRegular />} disabled={!p.canChange} onClick={act("unblock")} />}
      </TableCell>
    </TableRow>
  );
});

export function ProgramsPage({ hidden, sources }: { hidden: boolean; sources: Sources }) {
  const ops = useOps();
  const actions = useRuleActions();
  const [filter, setFilter] = useState("");
  const [show, setShow] = useState<Group>("all");

  const status = useMemo(() => statuses(ops.rules), [ops.rules]);
  const rows = useMemo(() => sources.list.map((f) => ({ f, g: group(stateOf(status.get(key(f.path)))) })), [sources.list, status]);
  const count = (g: Group) => (g === "all" ? rows.length : rows.filter((r) => r.g === g).length);
  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return rows.filter((r) => (show === "all" || r.g === show) && (!q || key(r.f.path).includes(q))).map((r) => r.f);
  }, [rows, filter, show]);
  const sel = useSelection(useMemo(() => shown.map((f) => f.path), [shown]));
  const picked = shown.filter((f) => sel.selected.has(f.path));
  // nothing selected: actions apply to what the filters show
  const targets = (picked.length ? picked : shown).map((f) => f.path);
  const canChange = ops.canChange && !ops.busy;
  const busy = !!ops.busy;

  const onAction = useStable((a: RowAction, path: string) => {
    if (a === "reveal") return api.reveal(path);
    if (a === "block") return actions.block([path], false);
    if (a === "unblock") return actions.unblock([path], false);
    return actions.setEnabled([path], a === "resume", false);
  });

  if (!sources.sources.length) {
    return (
      <section className="page" hidden={hidden}>
        <DropHome sources={sources} busy={busy} />
      </section>
    );
  }

  const groups: Group[] = ["all", "blocked", "partial", "paused", "allowed"];
  return (
    <section className="page" hidden={hidden}>
      {actions.dialog}
      <div className="toolbar">
        <Menu>
          <MenuTrigger disableButtonEnhancement>
            <Button icon={<AddRegular />} disabled={busy}>
              {t.programs.add}
            </Button>
          </MenuTrigger>
          <MenuPopover>
            <MenuList>
              <MenuItem icon={<FolderAddRegular />} onClick={sources.pickFolders}>
                {t.programs.addFolder}
              </MenuItem>
              <MenuItem icon={<AppsAddInRegular />} onClick={sources.pickPrograms}>
                {t.programs.addPrograms}
              </MenuItem>
            </MenuList>
          </MenuPopover>
        </Menu>
        <Tooltip content={t.programs.rescan} relationship="label">
          <Button icon={<ArrowSyncRegular />} onClick={sources.rescan} disabled={busy} />
        </Tooltip>
        <SearchBox className="grow" placeholder={t.common.filter} value={filter} onChange={(_, d) => setFilter(d.value)} />
        <Button appearance="primary" icon={<ShieldDismissRegular />} disabled={!canChange || !targets.length} onClick={() => actions.block(targets)}>
          {`${t.common.block} (${targets.length})`}
        </Button>
        <Button icon={<ShieldCheckmarkRegular />} disabled={!canChange || !targets.length} onClick={() => actions.unblock(targets)}>
          {`${t.common.unblock} (${targets.length})`}
        </Button>
        <Menu>
          <MenuTrigger disableButtonEnhancement>
            <Tooltip content={t.common.more} relationship="label">
              <Button icon={<MoreHorizontalRegular />} disabled={!canChange || !targets.length} />
            </Tooltip>
          </MenuTrigger>
          <MenuPopover>
            <MenuList>
              <MenuItem icon={<PauseRegular />} onClick={() => actions.setEnabled(targets, false)}>
                {`${t.common.pause} (${targets.length})`}
              </MenuItem>
              <MenuItem icon={<PlayRegular />} onClick={() => actions.setEnabled(targets, true)}>
                {`${t.common.resume} (${targets.length})`}
              </MenuItem>
            </MenuList>
          </MenuPopover>
        </Menu>
      </div>
      <div className="chips">
        <TagGroup
          size="small"
          onDismiss={(_, d) => {
            const src = sources.sources.find((s) => s.path === d.value);
            if (src) sources.remove(src);
          }}
        >
          {sources.sources.map((s) => (
            <Tag
              key={s.path}
              value={s.path}
              title={s.path}
              shape="circular"
              dismissible
              dismissIcon={{ "aria-label": t.programs.remove }}
              icon={s.kind === "folder" ? <FolderRegular /> : <ProgramIcon path={s.path} />}
            >
              {fileName(s.path) || s.path}
            </Tag>
          ))}
        </TagGroup>
        <Button appearance="subtle" size="small" onClick={sources.clear} disabled={busy}>
          {t.common.clear}
        </Button>
      </div>
      <FilterBar value={show} onChange={setShow} options={groups.map((g) => ({ value: g, label: t.programs[g], count: count(g) }))} />
      <div className="list">
        {!!sources.list.length && (
          <Table noNativeElements size="medium" className="table" aria-label={t.nav.folder}>
            <TableHeader className="thead">
              <TableRow>
                <TableSelectionCell checked={sel.headerState} onClick={sel.toggleShown} checkboxIndicator={{ "aria-label": t.common.selectAll }} />
                <TableHeaderCell style={COL.name}>{t.programs.colName}</TableHeaderCell>
                <TableHeaderCell style={COL.size}>{t.programs.colSize}</TableHeaderCell>
                <TableHeaderCell style={COL.status}>{t.programs.colStatus}</TableHeaderCell>
                <TableHeaderCell style={COL.actions} aria-hidden />
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map((f) => (
                <FileRow
                  key={f.path}
                  file={f}
                  s={status.get(key(f.path))}
                  selected={sel.selected.has(f.path)}
                  canChange={canChange}
                  onToggle={sel.toggle}
                  onAction={onAction}
                />
              ))}
            </TableBody>
          </Table>
        )}
        {!shown.length && <p className="muted no-match">{t.programs.noMatch}</p>}
      </div>
    </section>
  );
}
