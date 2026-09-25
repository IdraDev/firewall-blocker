// Firewall engine over the INetFwPolicy2 COM API. Mirrors script/lib/engine.ps1:
// same group, display names and legacy v1 detection, rules matched on
// program + direction.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use windows::Win32::Foundation::{VARIANT_FALSE, VARIANT_TRUE};
use windows::Win32::NetworkManagement::WindowsFirewall::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Ole::IEnumVARIANT;
use windows::Win32::System::Variant::{VARIANT, VariantClear};
use windows::core::{BSTR, Interface, Result};

pub const GROUP: &str = "FirewallBlocker";

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct RuleInfo {
    pub program: String,
    pub inbound: bool,
    pub legacy: bool,
    pub enabled: bool,
    pub missing: bool,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Target {
    pub program: String,
    pub inbound: bool,
    #[serde(default = "yes")]
    pub enabled: bool,
}

fn yes() -> bool {
    true
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum Request {
    Block { targets: Vec<Target> },
    // targets = None: every group rule; legacy: also match v1 rules
    Unblock { targets: Option<Vec<Target>>, legacy: bool },
    SetEnabled { targets: Vec<Target>, enabled: bool },
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    Created,
    Skipped,
    Enabled,
    Removed,
    Paused,
    Resumed,
    Failed,
}

// `enabled` is the rule state before the operation, so it can be undone.
#[derive(Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OpResult {
    pub program: String,
    pub inbound: bool,
    pub legacy: bool,
    pub enabled: bool,
    pub outcome: Outcome,
    pub error: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct Done {
    pub cancelled: bool,
    pub results: Vec<OpResult>,
}

struct Rule {
    com: INetFwRule,
    info: RuleInfo,
}

pub struct Com;

impl Com {
    pub fn init(model: COINIT) -> Result<Com> {
        unsafe { CoInitializeEx(None, model).ok()? };
        Ok(Com)
    }
}

impl Drop for Com {
    fn drop(&mut self) {
        unsafe { CoUninitialize() }
    }
}

fn policy() -> Result<INetFwPolicy2> {
    unsafe { CoCreateInstance(&NetFwPolicy2, None, CLSCTX_INPROC_SERVER) }
}

pub fn path_hash(path: &str) -> String {
    let d = md5::compute(path.to_lowercase().as_bytes());
    d.0[..8].iter().map(|b| format!("{b:02x}")).collect()
}

fn key(path: &str) -> String {
    path.to_lowercase()
}

// v1 rules: "Block <name> Inbound|Outbound" (case-insensitive), the suffix
// giving the direction.
fn legacy_direction(name: &str) -> Option<bool> {
    let n = name.to_lowercase();
    let rest = n.strip_prefix("block ")?;
    if rest.len() > 8 && rest.ends_with(" inbound") {
        Some(true)
    } else if rest.len() > 9 && rest.ends_with(" outbound") {
        Some(false)
    } else {
        None
    }
}

// Group rules plus legacy v1 rules (outside the group, action block,
// direction matching the name). Rules without a program are skipped.
fn rules(policy: &INetFwPolicy2) -> Result<Vec<Rule>> {
    let mut out = Vec::new();
    let mut exists: HashMap<String, bool> = HashMap::new();
    unsafe {
        let en: IEnumVARIANT = policy.Rules()?._NewEnum()?.cast()?;
        loop {
            let mut v = [VARIANT::default()];
            let mut fetched = 0;
            let _ = en.Next(&mut v, &mut fetched);
            if fetched == 0 {
                break;
            }
            let rule = (*v[0].Anonymous.Anonymous).Anonymous.pdispVal.as_ref().and_then(|d| d.cast::<INetFwRule>().ok());
            VariantClear(&mut v[0])?;
            let Some(rule) = rule else { continue };
            let inbound = rule.Direction()? == NET_FW_RULE_DIR_IN;
            let legacy = if rule.Grouping()?.to_string().eq_ignore_ascii_case(GROUP) {
                false
            } else if legacy_direction(&rule.Name()?.to_string()) == Some(inbound) && rule.Action()? == NET_FW_ACTION_BLOCK {
                true
            } else {
                continue;
            };
            let program = rule.ApplicationName().map(|p| p.to_string()).unwrap_or_default();
            if program.is_empty() {
                continue;
            }
            let enabled = rule.Enabled()?.as_bool();
            let missing = !*exists.entry(key(&program)).or_insert_with(|| Path::new(&program).exists());
            out.push(Rule { com: rule, info: RuleInfo { program, inbound, legacy, enabled, missing } });
        }
    }
    Ok(out)
}

pub fn list() -> Result<Vec<RuleInfo>> {
    let _com = Com::init(COINIT_MULTITHREADED)?;
    let rules = rules(&policy()?)?;
    Ok(rules.into_iter().map(|r| r.info).collect())
}

fn add_rule(rules: &INetFwRules, t: &Target) -> Result<()> {
    let name = Path::new(&t.program).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let dir = if t.inbound { "In" } else { "Out" };
    unsafe {
        let rule: INetFwRule = CoCreateInstance(&NetFwRule, None, CLSCTX_INPROC_SERVER)?;
        rule.SetName(&BSTR::from(format!("FirewallBlocker: {name} [{}] {dir}", path_hash(&t.program))))?;
        rule.SetDescription(&BSTR::from(&t.program))?;
        rule.SetApplicationName(&BSTR::from(&t.program))?;
        rule.SetGrouping(&BSTR::from(GROUP))?;
        rule.SetDirection(if t.inbound { NET_FW_RULE_DIR_IN } else { NET_FW_RULE_DIR_OUT })?;
        rule.SetAction(NET_FW_ACTION_BLOCK)?;
        rule.SetProfiles(NET_FW_PROFILE2_ALL.0)?;
        rule.SetEnabled(if t.enabled { VARIANT_TRUE } else { VARIANT_FALSE })?;
        rules.Add(&rule)
    }
}

// INetFwRules.Remove works by display name, and v1 rules share names across
// folders: give the exact rule a unique name first, then remove that.
// ponytail: ~80 ms per rule (vs ~5 ms to add); delete by rule ID via WMI MSFT_NetFirewallRule if bulk unblock speed matters
fn remove_rule(rules: &INetFwRules, rule: &INetFwRule, n: usize) -> Result<()> {
    let tmp = BSTR::from(format!("FirewallBlocker-remove-{}-{n}", std::process::id()));
    unsafe {
        let old = rule.Name()?;
        rule.SetName(&tmp)?;
        rules.Remove(&tmp).inspect_err(|_| {
            let _ = rule.SetName(&old);
        })
    }
}

fn set_enabled(rule: &INetFwRule, enabled: bool) -> Result<()> {
    unsafe { rule.SetEnabled(if enabled { VARIANT_TRUE } else { VARIANT_FALSE }) }
}

fn result(r: &RuleInfo, res: Result<Outcome>) -> OpResult {
    let (outcome, error) = match res {
        Ok(o) => (o, None),
        Err(e) => (Outcome::Failed, Some(e.message())),
    };
    OpResult { program: r.program.clone(), inbound: r.inbound, legacy: r.legacy, enabled: r.enabled, outcome, error }
}

fn target_keys(targets: &[Target]) -> HashSet<(String, bool)> {
    targets.iter().map(|t| (key(&t.program), t.inbound)).collect()
}

pub type Progress<'a> = &'a mut dyn FnMut(usize, usize);

// One engine entry point for both the in-process path and the elevated helper.
pub fn run(req: &Request, cancelled: &dyn Fn() -> bool, progress: Progress) -> Result<Done> {
    let _com = Com::init(COINIT_MULTITHREADED)?;
    let policy = policy()?;
    let all = rules(&policy)?;
    let com_rules = unsafe { policy.Rules()? };
    let mut results = Vec::new();
    // each job yields one result; stops early when cancelled
    let mut each = |total: usize, results: &mut Vec<OpResult>, job: &mut dyn FnMut(usize) -> OpResult| {
        for n in 0..total {
            if cancelled() {
                return true;
            }
            results.push(job(n));
            progress(results.len(), total);
        }
        false
    };
    let stopped = match req {
        // a paused group rule counts as existing and gets re-enabled
        Request::Block { targets } => {
            let existing: HashMap<(String, bool), &Rule> =
                all.iter().filter(|r| !r.info.legacy).map(|r| ((key(&r.info.program), r.info.inbound), r)).collect();
            each(targets.len(), &mut results, &mut |n| {
                let t = &targets[n];
                match existing.get(&(key(&t.program), t.inbound)) {
                    Some(r) if r.info.enabled || !t.enabled => result(&r.info, Ok(Outcome::Skipped)),
                    Some(r) => result(&r.info, set_enabled(&r.com, true).map(|_| Outcome::Enabled)),
                    None => {
                        let info = RuleInfo { program: t.program.clone(), inbound: t.inbound, legacy: false, enabled: t.enabled, missing: false };
                        result(&info, add_rule(&com_rules, t).map(|_| Outcome::Created))
                    }
                }
            })
        }
        Request::Unblock { targets, legacy } => {
            let wanted = targets.as_deref().map(target_keys);
            let hit: Vec<&Rule> = all
                .iter()
                .filter(|r| match &wanted {
                    None => !r.info.legacy,
                    Some(set) => (*legacy || !r.info.legacy) && set.contains(&(key(&r.info.program), r.info.inbound)),
                })
                .collect();
            each(hit.len(), &mut results, &mut |n| result(&hit[n].info, remove_rule(&com_rules, &hit[n].com, n).map(|_| Outcome::Removed)))
        }
        Request::SetEnabled { targets, enabled } => {
            let wanted = target_keys(targets);
            let hit: Vec<&Rule> = all.iter().filter(|r| wanted.contains(&(key(&r.info.program), r.info.inbound))).collect();
            let done = if *enabled { Outcome::Resumed } else { Outcome::Paused };
            each(hit.len(), &mut results, &mut |n| {
                let r = hit[n];
                let res = if r.info.enabled == *enabled { Ok(Outcome::Skipped) } else { set_enabled(&r.com, *enabled).map(|_| done) };
                result(&r.info, res)
            })
        }
    };
    Ok(Done { cancelled: stopped, results })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_matches_engine_ps1() {
        // Get-PathHash 'C:\Games\Setup.exe' in script/lib/engine.ps1
        assert_eq!(path_hash(r"C:\Games\Setup.exe"), "e9eff1ee908750ee");
        assert_eq!(path_hash(r"c:\games\SETUP.EXE"), path_hash(r"C:\Games\Setup.exe"));
    }

    #[test]
    fn legacy_names() {
        assert_eq!(legacy_direction("Block game.exe Inbound"), Some(true));
        assert_eq!(legacy_direction("block Game Of Life.exe OUTBOUND"), Some(false));
        assert_eq!(legacy_direction("Block  Inbound"), None);
        assert_eq!(legacy_direction("FirewallBlocker: a.exe [0123] In"), None);
        assert_eq!(legacy_direction("Allow game.exe Inbound"), None);
    }

    #[test]
    fn request_wire_format() {
        let r: Request = serde_json::from_str(r#"{"op":"setEnabled","targets":[{"program":"C:\\a.exe","inbound":true}],"enabled":false}"#).unwrap();
        assert!(matches!(r, Request::SetEnabled { ref targets, enabled: false } if targets[0].enabled));
    }

    // COM objects must be released before CoUninitialize: edition 2021 kept
    // tail-expression temporaries alive past it and crashed here
    #[test]
    fn list_twice_without_crash() {
        assert_eq!(list().unwrap().len(), list().unwrap().len());
    }

    // Needs an elevated shell: cargo test -- --ignored
    #[test]
    #[ignore]
    fn block_pause_unblock_roundtrip() {
        let dir = std::env::temp_dir().join(format!("fwb-rs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("probe.exe");
        std::fs::write(&exe, b"x").unwrap();
        let path = exe.to_string_lossy().into_owned();
        let both = |enabled| [true, false].map(|inbound| Target { program: path.clone(), inbound, enabled }).to_vec();
        let go = |req: Request| run(&req, &|| false, &mut |_, _| {}).unwrap();
        let outcomes = |d: Done| d.results.iter().map(|r| r.outcome).collect::<Vec<_>>();

        assert_eq!(outcomes(go(Request::Block { targets: both(true) })), [Outcome::Created; 2]);
        assert_eq!(outcomes(go(Request::Block { targets: both(true) })), [Outcome::Skipped; 2]);
        assert_eq!(outcomes(go(Request::SetEnabled { targets: both(true), enabled: false })), [Outcome::Paused; 2]);
        let mine = || list().unwrap().into_iter().filter(|r| key(&r.program) == key(&path)).collect::<Vec<_>>();
        assert!(mine().iter().all(|r| !r.enabled));
        assert_eq!(outcomes(go(Request::Block { targets: both(true) })), [Outcome::Enabled; 2]);
        let upper = [true, false].map(|inbound| Target { program: path.to_uppercase(), inbound, enabled: true }).to_vec();
        assert_eq!(outcomes(go(Request::Unblock { targets: Some(upper), legacy: false })), [Outcome::Removed; 2]);
        assert!(mine().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
