// Firewall engine over the INetFwPolicy2 COM API. Mirrors script/lib/engine.ps1:
// same group, display names and legacy v1 detection, rules matched on
// program + direction.

use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use windows::core::{Interface, Result, BSTR};
use windows::Win32::Foundation::VARIANT_TRUE;
use windows::Win32::NetworkManagement::WindowsFirewall::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Ole::IEnumVARIANT;
use windows::Win32::System::Variant::{VariantClear, VARIANT};

pub const GROUP: &str = "FirewallBlocker";

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct RuleInfo {
    pub program: String,
    pub inbound: bool,
    pub legacy: bool,
    pub missing: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpResult {
    pub program: String,
    pub inbound: bool,
    pub legacy: bool,
    pub outcome: &'static str,
    pub error: Option<String>,
}

#[derive(Serialize)]
pub struct Done {
    pub cancelled: bool,
    pub results: Vec<OpResult>,
}

struct Rule {
    com: INetFwRule,
    info: RuleInfo,
}

struct Com;

impl Com {
    fn init() -> Result<Com> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok()? };
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
            let missing = !*exists.entry(key(&program)).or_insert_with(|| Path::new(&program).exists());
            out.push(Rule { com: rule, info: RuleInfo { program, inbound, legacy, missing } });
        }
    }
    Ok(out)
}

pub fn list() -> Result<Vec<RuleInfo>> {
    let _com = Com::init()?;
    Ok(rules(&policy()?)?.into_iter().map(|r| r.info).collect())
}

fn add_rule(rules: &INetFwRules, path: &str, inbound: bool) -> Result<()> {
    let name = Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let dir = if inbound { "In" } else { "Out" };
    unsafe {
        let rule: INetFwRule = CoCreateInstance(&NetFwRule, None, CLSCTX_INPROC_SERVER)?;
        rule.SetName(&BSTR::from(format!("FirewallBlocker: {name} [{}] {dir}", path_hash(path))))?;
        rule.SetDescription(&BSTR::from(path))?;
        rule.SetApplicationName(&BSTR::from(path))?;
        rule.SetGrouping(&BSTR::from(GROUP))?;
        rule.SetDirection(if inbound { NET_FW_RULE_DIR_IN } else { NET_FW_RULE_DIR_OUT })?;
        rule.SetAction(NET_FW_ACTION_BLOCK)?;
        rule.SetProfiles(NET_FW_PROFILE2_ALL.0)?;
        rule.SetEnabled(VARIANT_TRUE)?;
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

fn outcome(program: &str, inbound: bool, legacy: bool, res: Result<&'static str>) -> OpResult {
    let (outcome, error) = match res {
        Ok(o) => (o, None),
        Err(e) => ("failed", Some(e.message())),
    };
    OpResult { program: program.to_string(), inbound, legacy, outcome, error }
}

// Creates In + Out block rules, skipping directions a group rule already
// covers. Progress unit = one rule op (files x 2).
pub fn block(paths: &[String], cancel: &AtomicBool, progress: impl Fn(usize, usize)) -> Result<Done> {
    let _com = Com::init()?;
    let policy = policy()?;
    let existing: HashSet<(String, bool)> =
        rules(&policy)?.into_iter().filter(|r| !r.info.legacy).map(|r| (key(&r.info.program), r.info.inbound)).collect();
    let com_rules = unsafe { policy.Rules()? };
    let total = paths.len() * 2;
    let mut results = Vec::with_capacity(total);
    for path in paths {
        for inbound in [true, false] {
            if cancel.load(Ordering::Relaxed) {
                return Ok(Done { cancelled: true, results });
            }
            let res = if existing.contains(&(key(path), inbound)) {
                Ok("skipped")
            } else {
                add_rule(&com_rules, path, inbound).map(|_| "created")
            };
            results.push(outcome(path, inbound, false, res));
            progress(results.len(), total);
        }
    }
    Ok(Done { cancelled: false, results })
}

// paths = None removes every group rule (legacy excluded, like the script's
// "Everything"); Some removes group and legacy rules for those programs.
pub fn unblock(paths: Option<&[String]>, cancel: &AtomicBool, progress: impl Fn(usize, usize)) -> Result<Done> {
    let _com = Com::init()?;
    let policy = policy()?;
    let wanted: Option<HashSet<String>> = paths.map(|p| p.iter().map(|s| key(s)).collect());
    let targets: Vec<Rule> = rules(&policy)?
        .into_iter()
        .filter(|r| match &wanted {
            None => !r.info.legacy,
            Some(set) => set.contains(&key(&r.info.program)),
        })
        .collect();
    let com_rules = unsafe { policy.Rules()? };
    let total = targets.len();
    let mut results = Vec::with_capacity(total);
    for (n, t) in targets.iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            return Ok(Done { cancelled: true, results });
        }
        let res = remove_rule(&com_rules, &t.com, n).map(|_| "removed");
        results.push(outcome(&t.info.program, t.info.inbound, t.info.legacy, res));
        progress(results.len(), total);
    }
    Ok(Done { cancelled: false, results })
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

    // COM objects must be released before CoUninitialize: edition 2021 kept
    // tail-expression temporaries alive past it and crashed here
    #[test]
    fn list_twice_without_crash() {
        assert_eq!(list().unwrap().len(), list().unwrap().len());
    }

    // Needs an elevated shell: cargo test -- --ignored
    #[test]
    #[ignore]
    fn block_then_unblock_roundtrip() {
        let dir = std::env::temp_dir().join(format!("fwb-rs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("probe.exe");
        std::fs::write(&exe, b"x").unwrap();
        let path = exe.to_string_lossy().into_owned();
        let stop = AtomicBool::new(false);

        let done = block(&[path.clone()], &stop, |_, _| {}).unwrap();
        assert!(done.results.iter().all(|r| r.outcome == "created"), "{:?}", done.results.iter().map(|r| &r.error).collect::<Vec<_>>());
        let again = block(&[path.clone()], &stop, |_, _| {}).unwrap();
        assert!(again.results.iter().all(|r| r.outcome == "skipped"));
        let mine = |l: &[RuleInfo]| l.iter().filter(|r| key(&r.program) == key(&path)).count();
        assert_eq!(mine(&list().unwrap()), 2);

        let gone = unblock(Some(&[path.to_uppercase()]), &stop, |_, _| {}).unwrap();
        assert_eq!(gone.results.iter().filter(|r| r.outcome == "removed").count(), 2);
        assert_eq!(mine(&list().unwrap()), 0);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
