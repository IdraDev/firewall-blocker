import { Body1, Button, Caption1, Subtitle1, Subtitle2 } from "@fluentui/react-components";
import { AppsAddInRegular, ArrowDownloadRegular, FolderAddRegular, FolderRegular } from "@fluentui/react-icons";
import { fileName } from "./api";
import { t } from "./i18n";
import type { Sources } from "./sources";
import { ProgramIcon } from "./ui";

// Empty list: the whole page is the drop target, with pickers and recents.
export function DropHome({ sources, busy }: { sources: Sources; busy: boolean }) {
  return (
    <div className="home">
      <div className="drop-zone">
        <ArrowDownloadRegular className="drop-icon" />
        <Subtitle1>{t.programs.dropTitle}</Subtitle1>
        <Body1 className="muted">{t.programs.dropBody}</Body1>
        <div className="toolbar">
          <Button appearance="primary" icon={<FolderAddRegular />} onClick={sources.pickFolders} disabled={busy}>
            {t.programs.addFolder}
          </Button>
          <Button icon={<AppsAddInRegular />} onClick={sources.pickPrograms} disabled={busy}>
            {t.programs.addPrograms}
          </Button>
        </div>
      </div>
      {sources.recents.length > 0 && (
        <>
          <Subtitle2 className="section">{t.programs.recent}</Subtitle2>
          {sources.recents.map((r) => (
            <button key={r.path} type="button" className="card recent" disabled={busy} onClick={() => sources.add([r.path])}>
              <span className="card-icon">{r.kind === "folder" ? <FolderRegular /> : <ProgramIcon path={r.path} />}</span>
              <span className="grow">
                <Body1 block>{fileName(r.path) || r.path}</Body1>
                <Caption1 block truncate wrap={false} className="muted">
                  {r.path}
                </Caption1>
              </span>
            </button>
          ))}
        </>
      )}
    </div>
  );
}
