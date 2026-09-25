import { Tooltip } from "@fluentui/react-components";
import {
  bundleIcon,
  FolderFilled,
  FolderRegular,
  NavigationRegular,
  SettingsFilled,
  SettingsRegular,
  ShieldFilled,
  ShieldRegular,
} from "@fluentui/react-icons";
import type { ReactNode } from "react";
import { t } from "./i18n";

export type Page = "folder" | "rules" | "settings";

const icons = {
  folder: bundleIcon(FolderFilled, FolderRegular),
  rules: bundleIcon(ShieldFilled, ShieldRegular),
  settings: bundleIcon(SettingsFilled, SettingsRegular),
};

function NavItem(p: { icon: ReactNode; label: string; current: boolean; collapsed: boolean; onClick: () => void }) {
  const button = (
    <button type="button" className="nav-item" aria-current={p.current ? "page" : undefined} onClick={p.onClick}>
      <span className="nav-icon">{p.icon}</span>
      <span className="nav-label">{p.label}</span>
    </button>
  );
  // the clipped label still names the button, so the tooltip is visual only
  return p.collapsed ? (
    <Tooltip content={p.label} relationship="inaccessible" positioning="after">
      {button}
    </Tooltip>
  ) : (
    button
  );
}

// WinUI NavigationView: hamburger toggles between labels and an icon rail.
export function NavPane(p: { page: Page; onPage: (page: Page) => void; collapsed: boolean; onToggle: () => void }) {
  const item = (page: Page) => {
    const Icon = icons[page];
    return (
      <NavItem
        icon={<Icon filled={p.page === page} />}
        label={t.nav[page]}
        current={p.page === page}
        collapsed={p.collapsed}
        onClick={() => p.onPage(page)}
      />
    );
  };
  return (
    <nav className={p.collapsed ? "nav collapsed" : "nav"}>
      <Tooltip content={p.collapsed ? t.nav.expand : t.nav.collapse} relationship="label" positioning="after">
        <button type="button" className="nav-item nav-toggle" aria-expanded={!p.collapsed} onClick={p.onToggle}>
          <span className="nav-icon">
            <NavigationRegular />
          </span>
        </button>
      </Tooltip>
      {item("folder")}
      {item("rules")}
      <div className="grow" />
      {item("settings")}
    </nav>
  );
}
