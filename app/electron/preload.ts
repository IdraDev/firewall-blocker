import { contextBridge, ipcRenderer } from "electron";

export type ExeFile = { name: string; path: string; size: number };
export type LogEntry = { level: "info" | "ok" | "error"; msg: string };

const api = {
  getInfo: () =>
    ipcRenderer.invoke("app:info") as Promise<{
      isAdmin: boolean;
      platform: string;
      version: string;
      user: string;
    }>,
  pickFolder: () => ipcRenderer.invoke("dialog:pickFolder") as Promise<string | null>,
  scanExe: (dir: string) => ipcRenderer.invoke("scan:exe", dir) as Promise<ExeFile[]>,
  rulesStatus: (paths: string[]) =>
    ipcRenderer.invoke("rules:status", paths) as Promise<Record<string, boolean>>,
  block: (files: { name: string; path: string }[]) =>
    ipcRenderer.invoke("action:block", files) as Promise<{ ok: number; fail: number }>,
  unblock: (files: { name: string; path: string }[]) =>
    ipcRenderer.invoke("action:unblock", files) as Promise<{ ok: number; fail: number }>,
  reveal: (p: string) => ipcRenderer.invoke("shell:openPath", p),
  onLog: (cb: (e: LogEntry) => void) => {
    const handler = (_: unknown, payload: LogEntry) => cb(payload);
    ipcRenderer.on("log", handler);
    return () => ipcRenderer.removeListener("log", handler);
  },
  onRuleUpdate: (cb: (e: { path: string; blocked: boolean }) => void) => {
    const handler = (_: unknown, payload: { path: string; blocked: boolean }) => cb(payload);
    ipcRenderer.on("rule:update", handler);
    return () => ipcRenderer.removeListener("rule:update", handler);
  },
  onProgress: (cb: (e: { done: number; total: number }) => void) => {
    const handler = (_: unknown, payload: { done: number; total: number }) => cb(payload);
    ipcRenderer.on("progress", handler);
    return () => ipcRenderer.removeListener("progress", handler);
  },
  win: {
    minimize: () => ipcRenderer.invoke("win:minimize"),
    maximize: () => ipcRenderer.invoke("win:maximize"),
    close: () => ipcRenderer.invoke("win:close"),
  },
};

contextBridge.exposeInMainWorld("fb", api);

export type FBApi = typeof api;
