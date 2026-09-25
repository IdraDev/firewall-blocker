import {
  createDarkTheme,
  createLightTheme,
  FluentProvider,
  MessageBar,
  MessageBarBody,
  Subtitle1,
  Title2,
  ToggleButton,
  type BrandVariants,
  type Theme,
} from "@fluentui/react-components";
import { ArrowDownloadRegular, HistoryRegular } from "@fluentui/react-icons";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useState } from "react";
import { ProgramsPage } from "./ProgramsPage";
import { t } from "./i18n";
import { NavPane, type Page } from "./Nav";
import { OpsProvider, useOps } from "./ops";
import { ActivityPanel, OperationBar, SummaryBar } from "./OpStatus";
import { RulesPage } from "./RulesPage";
import { SettingsPage, type ThemeSetting } from "./SettingsPage";
import { useSources } from "./sources";
import { useStable } from "./ui";

// Flame orange #FF5B3C at 100; 70/80 darkened so white text on brand passes 4.5:1.
const flame: BrandVariants = {
  10: "#150604", 20: "#2E0D07", 30: "#47140A", 40: "#601B0D", 50: "#792311", 60: "#922A14",
  70: "#AB3117", 80: "#C4381A", 90: "#E14A2B", 100: "#FF5B3C", 110: "#FF7257", 120: "#FF8972",
  130: "#FFA08E", 140: "#FFB7A9", 150: "#FFCEC4", 160: "#FFE5DF",
};

const fonts = {
  fontFamilyBase: '"Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif',
  fontFamilyMonospace: '"Cascadia Mono", Consolas, monospace',
};

const themes: Record<"light" | "dark", Theme> = {
  light: { ...createLightTheme(flame), ...fonts },
  // Win11 dark accent: light fill, black text
  dark: {
    ...createDarkTheme(flame),
    ...fonts,
    colorBrandForeground1: flame[110],
    colorBrandForeground2: flame[120],
    colorBrandBackground: flame[100],
    colorBrandBackgroundHover: flame[110],
    colorBrandBackgroundPressed: flame[90],
    colorBrandBackgroundSelected: flame[100],
    colorNeutralForegroundOnBrand: "#000000",
  },
};

function useSystemDark() {
  const query = matchMedia("(prefers-color-scheme: dark)");
  const [dark, setDark] = useState(query.matches);
  useEffect(() => {
    const on = () => setDark(query.matches);
    query.addEventListener("change", on);
    return () => query.removeEventListener("change", on);
  }, []);
  return dark;
}

export default function App() {
  const [setting, setSetting] = useState<ThemeSetting>(() => (localStorage.getItem("theme") as ThemeSetting) ?? "system");
  const systemDark = useSystemDark();
  const mode = setting === "system" ? (systemDark ? "dark" : "light") : setting;

  useEffect(() => {
    localStorage.setItem("theme", setting);
    getCurrentWindow().setTheme(setting === "system" ? null : setting);
  }, [setting]);

  useEffect(() => {
    document.documentElement.style.colorScheme = mode;
  }, [mode]);

  return (
    <FluentProvider theme={themes[mode]} className={`app ${mode}`}>
      <OpsProvider>
        <Shell setting={setting} onSetting={setSetting} />
      </OpsProvider>
    </FluentProvider>
  );
}

function Shell({ setting, onSetting }: { setting: ThemeSetting; onSetting: (s: ThemeSetting) => void }) {
  const [page, setPage] = useState<Page>("folder");
  const [logOpen, setLogOpen] = useState(false);
  const [collapsed, setCollapsed] = useState(() => localStorage.getItem("navCollapsed") === "1");
  const [dragging, setDragging] = useState(false);
  const { env } = useOps();
  const sources = useSources();

  useEffect(() => {
    localStorage.setItem("navCollapsed", collapsed ? "1" : "0");
  }, [collapsed]);

  const drop = useStable((paths: string[]) => {
    setPage("folder");
    sources.add(paths);
  });

  // the window is the drop target: works because the app is not elevated
  useEffect(() => {
    const off = getCurrentWebview().onDragDropEvent(({ payload: p }) => {
      if (p.type === "enter" || p.type === "over") setDragging(true);
      else setDragging(false);
      if (p.type === "drop") drop(p.paths);
    });
    return () => void off.then((f) => f());
  }, []);

  return (
    <div className="shell">
      <NavPane page={page} onPage={setPage} collapsed={collapsed} onToggle={() => setCollapsed((c) => !c)} />
      <main className="content">
        <div className="page-col">
          <header className="page-header">
            <Title2>{t.nav[page]}</Title2>
            <ToggleButton appearance="subtle" icon={<HistoryRegular />} checked={logOpen} onClick={() => setLogOpen((o) => !o)}>
              {t.log.title}
            </ToggleButton>
          </header>
          <div className="notices">
            {env && !env.firewallRunning && (
              <MessageBar intent="error">
                <MessageBarBody>{t.banner.firewallOff}</MessageBarBody>
              </MessageBar>
            )}
            <OperationBar />
            <SummaryBar />
          </div>
          <ProgramsPage hidden={page !== "folder"} sources={sources} />
          <RulesPage hidden={page !== "rules"} />
          <SettingsPage hidden={page !== "settings"} setting={setting} onSetting={onSetting} />
        </div>
        <ActivityPanel open={logOpen} onClose={() => setLogOpen(false)} />
        {dragging && (
          <div className="drop-overlay">
            <ArrowDownloadRegular className="drop-icon" />
            <Subtitle1>{t.programs.dropNow}</Subtitle1>
          </div>
        )}
      </main>
    </div>
  );
}
