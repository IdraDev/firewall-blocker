import { Badge, Body1, Caption1, Dropdown, Option, Subtitle2 } from "@fluentui/react-components";
import { DarkThemeRegular, PersonKeyRegular, ShieldGlobeRegular } from "@fluentui/react-icons";
import { getVersion } from "@tauri-apps/api/app";
import { useEffect, useState, type ReactNode } from "react";
import { t } from "./i18n";
import logo from "./logo.svg";
import { useOps } from "./ops";

export type ThemeSetting = "system" | "light" | "dark";

function SettingCard({ icon, title, hint, children }: { icon: ReactNode; title: string; hint: string; children?: ReactNode }) {
  return (
    <div className="card">
      <span className="card-icon">{icon}</span>
      <div className="grow">
        <Body1 block>{title}</Body1>
        <Caption1 className="muted">{hint}</Caption1>
      </div>
      {children}
    </div>
  );
}

function YesNo({ ok, yes, no }: { ok?: boolean; yes: string; no: string }) {
  if (ok === undefined) return null;
  return (
    <Badge appearance="tint" color={ok ? "success" : "danger"}>
      {ok ? yes : no}
    </Badge>
  );
}

export function SettingsPage(p: { hidden: boolean; setting: ThemeSetting; onSetting: (s: ThemeSetting) => void }) {
  const { env } = useOps();
  const [version, setVersion] = useState("");
  useEffect(() => void getVersion().then(setVersion), []);
  const labels: Record<ThemeSetting, string> = { system: t.settings.system, light: t.settings.light, dark: t.settings.dark };

  return (
    <section className="page settings" hidden={p.hidden}>
      <Subtitle2 className="section">{t.settings.appearance}</Subtitle2>
      <SettingCard icon={<DarkThemeRegular />} title={t.settings.theme} hint={t.settings.themeHint}>
        <Dropdown
          value={labels[p.setting]}
          selectedOptions={[p.setting]}
          onOptionSelect={(_, d) => p.onSetting(d.optionValue as ThemeSetting)}
        >
          {(Object.keys(labels) as ThemeSetting[]).map((k) => (
            <Option key={k} value={k}>
              {labels[k]}
            </Option>
          ))}
        </Dropdown>
      </SettingCard>

      <Subtitle2 className="section">{t.settings.status}</Subtitle2>
      <SettingCard icon={<PersonKeyRegular />} title={t.settings.consent} hint={t.settings.consentHint}>
        {env && (
          <Badge appearance="tint" color={env.admin || env.helper ? "success" : "informative"}>
            {env.admin ? t.settings.appAdmin : env.helper ? t.settings.granted : t.settings.notYet}
          </Badge>
        )}
      </SettingCard>
      <SettingCard icon={<ShieldGlobeRegular />} title={t.settings.firewall} hint={t.settings.firewallHint}>
        <YesNo ok={env?.firewallRunning} yes={t.settings.running} no={t.settings.stopped} />
      </SettingCard>

      <Subtitle2 className="section">{t.settings.about}</Subtitle2>
      <SettingCard icon={<img src={logo} alt="" className="card-logo" />} title={`Firewall Blocker ${version}`} hint={t.settings.aboutHint} />
    </section>
  );
}
