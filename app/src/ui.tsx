import {
  Body1,
  Button,
  Dialog,
  DialogActions,
  DialogBody,
  DialogContent,
  DialogSurface,
  DialogTitle,
  Radio,
  RadioGroup,
  Subtitle1,
  Tab,
  TabList,
} from "@fluentui/react-components";
import { AppGenericRegular } from "@fluentui/react-icons";
import { useCallback, useMemo, useRef, useState, type ReactNode } from "react";
import { iconUrl } from "./api";
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

// Real shell icon of the program, lazy-loaded from the icon:// protocol.
export function ProgramIcon({ path }: { path: string }) {
  const [failed, setFailed] = useState(false);
  if (failed) return <AppGenericRegular className="program-icon" />;
  return <img className="program-icon" src={iconUrl(path)} alt="" loading="lazy" draggable={false} onError={() => setFailed(true)} />;
}

// WinUI SelectorBar: one tab per status with its count.
export function FilterBar<T extends string>(p: { value: T; onChange: (v: T) => void; options: { value: T; label: string; count: number }[] }) {
  return (
    <TabList size="small" selectedValue={p.value} onTabSelect={(_, d) => p.onChange(d.value as T)} className="filter-bar">
      {p.options.map((o) => (
        <Tab key={o.value} value={o.value}>
          {`${o.label} ${o.count}`}
        </Tab>
      ))}
    </TabList>
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

type Options<T extends string> = {
  title: string;
  lines: (choice: T) => string[];
  ok: (choice: T) => string;
  initial: T;
  choices?: { value: T; label: string }[];
  enabled?: (choice: T) => boolean;
};

// Promise-based ContentDialog; resolves to the chosen option, or null on cancel.
export function useConfirm() {
  const [req, setReq] = useState<{ opts: Options<string>; resolve: (v: string | null) => void } | null>(null);
  const [choice, setChoice] = useState("");
  const close = (v: string | null) => {
    req?.resolve(v);
    setReq(null);
  };
  const o = req?.opts;
  const dialog = (
    <Dialog open={!!req} onOpenChange={(_, d) => !d.open && close(null)}>
      <DialogSurface>
        <DialogBody>
          <DialogTitle>{o?.title}</DialogTitle>
          <DialogContent>
            {o?.choices && (
              <RadioGroup value={choice} onChange={(_, d) => setChoice(d.value)} className="dialog-choices">
                {o.choices.map((c) => (
                  <Radio key={c.value} value={c.value} label={c.label} />
                ))}
              </RadioGroup>
            )}
            {o?.lines(choice).map((l) => (
              <p key={l}>{l}</p>
            ))}
          </DialogContent>
          <DialogActions>
            <Button appearance="primary" disabled={o?.enabled && !o.enabled(choice)} onClick={() => close(choice)}>
              {o?.ok(choice)}
            </Button>
            <Button onClick={() => close(null)}>{t.common.cancel}</Button>
          </DialogActions>
        </DialogBody>
      </DialogSurface>
    </Dialog>
  );
  const confirm = <T extends string>(opts: Options<T>) =>
    new Promise<T | null>((resolve) => {
      setChoice(opts.initial);
      setReq({ opts: opts as unknown as Options<string>, resolve: resolve as (v: string | null) => void });
    });
  const ask = (title: string, lines: string[], ok: string) =>
    confirm({ title, lines: () => lines, ok: () => ok, initial: "ok" }).then((v) => v !== null);
  return { dialog, confirm, ask };
}
