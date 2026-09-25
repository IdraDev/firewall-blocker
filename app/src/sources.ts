import { open } from "@tauri-apps/plugin-dialog";
import { useEffect, useMemo, useState } from "react";
import { api, key, type ExeFile } from "./api";
import { t } from "./i18n";
import { useOps } from "./ops";

export type Source = { path: string; kind: "folder" | "exe" };
export type Entry = ExeFile & { source: Source };

function stored<T>(name: string, fallback: T): T {
  try {
    return JSON.parse(localStorage.getItem(name) ?? "null") ?? fallback;
  } catch {
    return fallback;
  }
}

const same = (a: Source, b: Source) => key(a.path) === key(b.path);

// Folders and programs in the list: persisted and rescanned at start.
export function useSources() {
  const ops = useOps();
  const [sources, setSources] = useState<Source[]>(() => {
    const last = localStorage.getItem("lastFolder"); // builds before the list
    return stored("sources", last ? [{ path: last, kind: "folder" }] : []);
  });
  const [recents, setRecents] = useState<Source[]>(() => stored("recents", []));
  const [entries, setEntries] = useState<Entry[]>([]);

  useEffect(() => {
    localStorage.setItem("sources", JSON.stringify(sources));
    localStorage.removeItem("lastFolder");
  }, [sources]);

  useEffect(() => {
    localStorage.setItem("recents", JSON.stringify(recents));
  }, [recents]);

  async function read(src: Source): Promise<Entry[]> {
    if (src.kind === "folder") return ((await ops.scan(src.path))?.files ?? []).map((f) => ({ ...f, source: src }));
    const [item] = await api.inspect([src.path]);
    if (item?.kind === "exe") return [{ ...item.file, source: src }];
    ops.notify("error", t.programs.notFound, src.path);
    return [];
  }

  async function load(list: Source[]) {
    for (const src of list) {
      const fresh = await read(src);
      setEntries((e) => [...e.filter((x) => !same(x.source, src)), ...fresh]);
    }
  }

  useEffect(() => {
    load(sources);
  }, []);

  async function add(paths: string[]) {
    const items = await api.inspect(paths);
    const found: Source[] = [];
    for (const i of items) {
      const src: Source = { path: i.file.path, kind: i.kind === "folder" ? "folder" : "exe" };
      if (i.kind !== "other" && !found.some((f) => same(f, src))) found.push(src);
    }
    const ignored = items.filter((i) => i.kind === "other").length;
    if (ignored) ops.notify("warning", t.programs.ignored(ignored));
    setSources((s) => [...s, ...found.filter((f) => !s.some((x) => same(x, f)))]);
    setRecents((r) => [...found, ...r.filter((x) => !found.some((f) => same(f, x)))].slice(0, 8));
    await load(found);
  }

  async function pickFolders() {
    const dirs = await open({ directory: true, multiple: true, title: t.programs.chooseFolder });
    if (dirs?.length) await add(dirs);
  }

  async function pickPrograms() {
    const files = await open({
      multiple: true,
      title: t.programs.choosePrograms,
      filters: [{ name: t.programs.exeFilter, extensions: ["exe", "lnk"] }],
    });
    if (files?.length) await add(files);
  }

  // one row per program, even when two sources contain it
  const list = useMemo(() => {
    const seen = new Set<string>();
    return entries
      .filter((e) => !seen.has(key(e.path)) && !!seen.add(key(e.path)))
      .sort((a, b) => key(a.path).localeCompare(key(b.path)));
  }, [entries]);

  return {
    sources,
    recents,
    list,
    add,
    pickFolders,
    pickPrograms,
    rescan: () => load(sources),
    remove: (src: Source) => {
      setSources((s) => s.filter((x) => !same(x, src)));
      setEntries((e) => e.filter((x) => !same(x.source, src)));
    },
    clear: () => {
      setSources([]);
      setEntries([]);
    },
  };
}

export type Sources = ReturnType<typeof useSources>;
