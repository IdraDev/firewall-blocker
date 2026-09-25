import {
  Body1,
  Button,
  Dialog,
  DialogActions,
  DialogBody,
  DialogContent,
  DialogSurface,
  DialogTitle,
  Subtitle1,
} from "@fluentui/react-components";
import { useCallback, useMemo, useRef, useState, type ReactNode } from "react";
import { t } from "./i18n";

export function EmptyState({ icon, title, body }: { icon: ReactNode; title: string; body?: string }) {
  return (
    <div className="empty">
      <div className="empty-icon">{icon}</div>
      <Subtitle1>{title}</Subtitle1>
      {body && <Body1 className="muted">{body}</Body1>}
    </div>
  );
}

// Checkbox selection over a list of keys; `shown` scopes select-all to what the filter shows.
export function useSelection(shown: string[]) {
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const shownSet = useMemo(() => new Set(shown), [shown]);
  const shownSelected = shown.filter((k) => selected.has(k)).length;
  // stable, so memoized rows skip re-rendering when another row toggles
  const toggle = useCallback(
    (k: string) =>
      setSelected((s) => {
        const n = new Set(s);
        if (!n.delete(k)) n.add(k);
        return n;
      }),
    [],
  );
  return {
    selected,
    toggle,
    toggleShown: () =>
      setSelected((s) => {
        const n = new Set(s);
        const all = shownSelected === shown.length;
        for (const k of shownSet) all ? n.delete(k) : n.add(k);
        return n;
      }),
    clear: () => setSelected(new Set()),
    headerState: (shownSelected === 0 ? false : shownSelected === shown.length ? true : "mixed") as boolean | "mixed",
  };
}

// Stable identity, always calls the latest fn: keeps memoized rows cheap.
export function useStable<A extends unknown[]>(fn: (...a: A) => unknown) {
  const ref = useRef(fn);
  ref.current = fn;
  return useCallback((...a: A) => void ref.current(...a), []);
}

type ConfirmOptions ={ title: string; lines: string[]; ok: string };

// Promise-based ContentDialog: `if (await confirm({...}))`.
export function useConfirm() {
  const [req, setReq] = useState<{ opts: ConfirmOptions; resolve: (ok: boolean) => void } | null>(null);
  const close = (ok: boolean) => {
    req?.resolve(ok);
    setReq(null);
  };
  const dialog = (
    <Dialog open={!!req} onOpenChange={(_, d) => !d.open && close(false)}>
      <DialogSurface>
        <DialogBody>
          <DialogTitle>{req?.opts.title}</DialogTitle>
          <DialogContent>
            {req?.opts.lines.map((l) => (
              <p key={l}>{l}</p>
            ))}
          </DialogContent>
          <DialogActions>
            <Button appearance="primary" onClick={() => close(true)}>
              {req?.opts.ok}
            </Button>
            <Button onClick={() => close(false)}>{t.common.cancel}</Button>
          </DialogActions>
        </DialogBody>
      </DialogSurface>
    </Dialog>
  );
  const confirm = (opts: ConfirmOptions) => new Promise<boolean>((resolve) => setReq({ opts, resolve }));
  return [dialog, confirm] as const;
}
