import {
  Badge,
  Button,
  Caption1,
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
  AppGenericRegular,
  ArrowSyncRegular,
  FolderOpenRegular,
  FolderSearchRegular,
  OpenRegular,
  ShieldCheckmarkRegular,
  ShieldDismissRegular,
  ShieldErrorRegular,
} from "@fluentui/react-icons";
import { open } from "@tauri-apps/plugin-dialog";
import { memo, useEffect, useMemo, useState } from "react";
import { useRuleActions } from "./actions";
import { api, directions, key, type Directions, type ExeFile } from "./api";
import { bytes, t } from "./i18n";
import { useOps } from "./ops";
import { EmptyState, useSelection, useStable } from "./ui";

const COL = {
  name: { flex: "1 1 0", minWidth: "180px" },
  size: { flex: "0 0 112px", justifyContent: "flex-end", paddingRight: "24px" },
  status: { flex: "0 0 150px" },
  actions: { flex: "0 0 112px", justifyContent: "flex-end" },
};

type RowAction = "reveal" | "block" | "unblock";

function StatusBadge({ d }: { d?: Directions }) {
  if (d?.inbound && d.outbound)
    return (
      <Badge appearance="tint" color="brand" icon={<ShieldDismissRegular />}>
        {t.folder.blocked}
      </Badge>
    );
  if (d)
    return (
      <Badge appearance="tint" color="warning" icon={<ShieldErrorRegular />}>
        {d.inbound ? t.folder.inOnly : t.folder.outOnly}
      </Badge>
    );
  return (
    <Badge appearance="ghost" color="informative">
      {t.folder.allowed}
    </Badge>
  );
}

const FileRow = memo(function FileRow(p: {
  file: ExeFile;
  where: string;
  d?: Directions;
  selected: boolean;
  canChange: boolean;
  onToggle: (path: string) => void;
  onAction: (a: RowAction, path: string) => void;
}) {
  const { file, d } = p;
  return (
    <TableRow className="row" appearance={p.selected ? "brand" : "none"} aria-selected={p.selected} onClick={() => p.onToggle(file.path)}>
      <TableSelectionCell checked={p.selected} checkboxIndicator={{ "aria-label": t.common.select }} />
      <TableCell style={COL.name} title={file.path}>
        <TableCellLayout truncate media={<AppGenericRegular />} description={p.where}>
          {file.name}
        </TableCellLayout>
      </TableCell>
      <TableCell style={COL.size} className="num muted">
        {bytes(file.size)}
      </TableCell>
      <TableCell style={COL.status}>
        <StatusBadge d={d} />
      </TableCell>
      <TableCell style={COL.actions} onClick={(e) => e.stopPropagation()}>
        <Tooltip content={t.common.reveal} relationship="label">
          <Button appearance="subtle" icon={<OpenRegular />} onClick={() => p.onAction("reveal", file.path)} />
        </Tooltip>
        {!(d?.inbound && d.outbound) && (
          <Tooltip content={t.common.block} relationship="label">
            <Button appearance="subtle" icon={<ShieldDismissRegular />} disabled={!p.canChange} onClick={() => p.onAction("block", file.path)} />
          </Tooltip>
        )}
        {d && (
          <Tooltip content={t.common.unblock} relationship="label">
            <Button appearance="subtle" icon={<ShieldCheckmarkRegular />} disabled={!p.canChange} onClick={() => p.onAction("unblock", file.path)} />
          </Tooltip>
        )}
      </TableCell>
    </TableRow>
  );
});

export function FolderPage({ hidden }: { hidden: boolean }) {
  const ops = useOps();
  const actions = useRuleActions();
  const [folder, setFolder] = useState<string | null>(null);
  const [files, setFiles] = useState<ExeFile[] | null>(null);
  const [filter, setFilter] = useState("");

  const status = useMemo(() => directions(ops.rules), [ops.rules]);
  const shown = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return (files ?? []).filter((f) => !q || key(f.path).includes(q));
  }, [files, filter]);
  const sel = useSelection(useMemo(() => shown.map((f) => f.path), [shown]));
  const picked = shown.filter((f) => sel.selected.has(f.path));
  // nothing selected: bulk actions apply to what the filter shows
  const targets = (picked.length ? picked : shown).map((f) => f.path);
  const canChange = ops.canChange && !ops.busy;

  async function load(dir: string) {
    setFolder(dir);
    const scan = await ops.scan(dir);
    sel.clear();
    setFiles(scan?.files ?? null);
    if (scan) localStorage.setItem("lastFolder", dir);
    else localStorage.removeItem("lastFolder");
  }

  useEffect(() => {
    const last = localStorage.getItem("lastFolder");
    if (last) load(last);
  }, []);

  async function choose() {
    const dir = await open({ directory: true, title: t.folder.chooseTitle, defaultPath: folder ?? undefined });
    if (typeof dir === "string") load(dir);
  }

  const onAction = useStable((a: RowAction, path: string) =>
    a === "reveal" ? api.reveal(path) : a === "block" ? actions.block([path], false) : actions.unblock([path], false),
  );

  const counts = { blocked: 0, partial: 0 };
  for (const f of files ?? []) {
    const d = status.get(key(f.path));
    if (d?.inbound && d.outbound) counts.blocked++;
    else if (d) counts.partial++;
  }
  const total = files?.length ?? 0;
  const where = (f: ExeFile) => f.path.slice(folder?.replace(/\\$/, "").length ?? 0, -f.name.length - 1) || "\\";

  return (
    <section className="page" hidden={hidden}>
      {actions.dialog}
      <div className="toolbar">
        <Button appearance="primary" icon={<FolderOpenRegular />} onClick={choose} disabled={!!ops.busy}>
          {t.folder.choose}
        </Button>
        <Button icon={<ArrowSyncRegular />} onClick={() => folder && load(folder)} disabled={!folder || !!ops.busy}>
          {t.folder.rescan}
        </Button>
        <SearchBox className="grow" placeholder={t.common.filter} value={filter} onChange={(_, d) => setFilter(d.value)} />
        <Button icon={<ShieldDismissRegular />} disabled={!canChange || !targets.length} onClick={() => actions.block(targets)}>
          {`${t.common.block} (${targets.length})`}
        </Button>
        <Button icon={<ShieldCheckmarkRegular />} disabled={!canChange || !targets.length} onClick={() => actions.unblock(targets)}>
          {`${t.common.unblock} (${targets.length})`}
        </Button>
      </div>
      <Caption1 block truncate wrap={false} className="muted path" title={folder ?? undefined}>
        {folder ?? t.folder.none}
      </Caption1>
      <div className="list">
        {files === null ? (
          <EmptyState icon={<FolderSearchRegular />} title={t.folder.emptyTitle} body={t.folder.emptyBody} />
        ) : !files.length ? (
          <EmptyState icon={<FolderSearchRegular />} title={t.folder.noExeTitle} body={t.folder.noExeBody} />
        ) : (
          <Table noNativeElements size="medium" className="table" aria-label={t.nav.folder}>
            <TableHeader className="thead">
              <TableRow>
                <TableSelectionCell checked={sel.headerState} onClick={sel.toggleShown} checkboxIndicator={{ "aria-label": t.common.selectAll }} />
                <TableHeaderCell style={COL.name}>{t.folder.colName}</TableHeaderCell>
                <TableHeaderCell style={COL.size}>{t.folder.colSize}</TableHeaderCell>
                <TableHeaderCell style={COL.status}>{t.folder.colStatus}</TableHeaderCell>
                <TableHeaderCell style={COL.actions} aria-hidden />
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map((f) => (
                <FileRow
                  key={f.path}
                  file={f}
                  where={where(f)}
                  d={status.get(key(f.path))}
                  selected={sel.selected.has(f.path)}
                  canChange={canChange}
                  onToggle={sel.toggle}
                  onAction={onAction}
                />
              ))}
            </TableBody>
          </Table>
        )}
        {!!files?.length && !shown.length && <Caption1 className="muted no-match">{t.folder.noMatch}</Caption1>}
      </div>
      {!!total && (
        <Caption1 className="muted footer">
          {t.folder.stats(total, counts.blocked, counts.partial, total - counts.blocked - counts.partial)}
        </Caption1>
      )}
    </section>
  );
}
