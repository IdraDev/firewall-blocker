import {
  Button,
  Caption1,
  DrawerBody,
  DrawerHeader,
  DrawerHeaderTitle,
  InlineDrawer,
  MessageBar,
  MessageBarActions,
  MessageBarBody,
  MessageBarTitle,
  ProgressBar,
  Text,
} from "@fluentui/react-components";
import { ArrowUndoRegular, DeleteRegular, DismissRegular, RecordStopRegular } from "@fluentui/react-icons";
import { useEffect, useRef, useState } from "react";
import type { Progress } from "./api";
import { lang, num, t } from "./i18n";
import { failureText, progressBus, useOps } from "./ops";

export function OperationBar() {
  const { busy, cancel } = useOps();
  const [p, setP] = useState<Progress>({ done: 0, total: 0 });
  useEffect(() => {
    const on = (e: Event) => setP((e as CustomEvent<Progress>).detail);
    progressBus.addEventListener("progress", on);
    return () => progressBus.removeEventListener("progress", on);
  }, []);
  if (!busy) return null;
  const counted = busy.determinate && p.total > 0;
  return (
    <div className="opbar">
      <div className="opbar-row">
        <Text truncate wrap={false} className="grow">
          {busy.label}
        </Text>
        {counted && <Caption1 className="mono">{`${num(p.done)}/${num(p.total)}`}</Caption1>}
        <Button size="small" icon={<RecordStopRegular />} onClick={cancel}>
          {t.common.stop}
        </Button>
      </div>
      <ProgressBar value={counted ? p.done / p.total : undefined} thickness="large" />
    </div>
  );
}

export function SummaryBar() {
  const { summary, dismissSummary, undo, busy } = useOps();
  const [open, setOpen] = useState(false);
  useEffect(() => setOpen(false), [summary]);
  if (!summary) return null;
  const more = summary.failures.length - 10;
  return (
    <MessageBar intent={summary.intent} layout="multiline" className="summary">
      <MessageBarBody>
        <MessageBarTitle>{summary.title}</MessageBarTitle>
        {summary.body && <div>{summary.body}</div>}
        {open && (
          <ul className="failures">
            {summary.failures.slice(0, 10).map((f, i) => (
              <li key={i}>{failureText(f)}</li>
            ))}
            {more > 0 && <li>{t.op.moreErrors(more)}</li>}
          </ul>
        )}
      </MessageBarBody>
      <MessageBarActions
        containerAction={<Button appearance="transparent" icon={<DismissRegular />} aria-label={t.log.close} onClick={dismissSummary} />}
      >
        {summary.undo && (
          <Button icon={<ArrowUndoRegular />} disabled={!!busy} onClick={undo}>
            {t.op.undo}
          </Button>
        )}
        {summary.failures.length > 0 && (
          <Button onClick={() => setOpen((o) => !o)}>{open ? t.op.hideErrors : t.op.showErrors}</Button>
        )}
      </MessageBarActions>
    </MessageBar>
  );
}

export function ActivityPanel({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { log, clearLog } = useOps();
  const end = useRef<HTMLDivElement>(null);
  // braces matter: Chromium's scrollIntoView returns a Promise, which React would call as cleanup
  useEffect(() => {
    end.current?.scrollIntoView({ block: "end" });
  }, [log.length, open]);
  return (
    <InlineDrawer open={open} position="end" separator className="activity">
      <DrawerHeader>
        <DrawerHeaderTitle
          action={
            <>
              <Button appearance="subtle" icon={<DeleteRegular />} onClick={clearLog} disabled={!log.length}>
                {t.log.clear}
              </Button>
              <Button appearance="subtle" icon={<DismissRegular />} aria-label={t.log.close} onClick={onClose} />
            </>
          }
        >
          {t.log.title}
        </DrawerHeaderTitle>
      </DrawerHeader>
      <DrawerBody>
        {log.length === 0 && <Caption1 className="muted">{t.log.empty}</Caption1>}
        {log.map((l, i) => (
          <div key={i} className={`log-line ${l.level}`}>
            <span className="muted mono">{new Date(l.ts).toLocaleTimeString(lang)}</span> {l.msg}
          </div>
        ))}
        <div ref={end} />
      </DrawerBody>
    </InlineDrawer>
  );
}
