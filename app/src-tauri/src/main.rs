#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod fw;

use serde::Serialize;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::ipc::Channel;
use windows::core::w;
use windows::Win32::System::Services::*;
use windows::Win32::UI::Shell::IsUserAnAdmin;

// One operation runs at a time (the UI disables actions while busy).
static CANCEL: AtomicBool = AtomicBool::new(false);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EnvInfo {
    admin: bool,
    firewall_running: bool,
}

#[derive(Serialize)]
struct ExeFile {
    name: String,
    path: String,
    size: u64,
}

#[derive(Serialize, Default)]
struct Scan {
    files: Vec<ExeFile>,
    unreadable: usize,
    cancelled: bool,
}

#[derive(Serialize, Clone)]
struct Progress {
    done: usize,
    total: usize,
}

fn firewall_running() -> bool {
    unsafe {
        let Ok(scm) = OpenSCManagerW(None, None, SC_MANAGER_CONNECT) else { return false };
        let mut st = SERVICE_STATUS::default();
        let ok = match OpenServiceW(scm, w!("mpssvc"), SERVICE_QUERY_STATUS) {
            Ok(svc) => {
                let ok = QueryServiceStatus(svc, &mut st).is_ok();
                let _ = CloseServiceHandle(svc);
                ok
            }
            Err(_) => false,
        };
        let _ = CloseServiceHandle(scm);
        ok && st.dwCurrentState == SERVICE_RUNNING
    }
}

// Junctions and symlinks report as neither dir nor file, so they are never
// followed: no loops.
fn exe_files(dir: &str) -> Scan {
    let mut scan = Scan::default();
    let mut stack = vec![PathBuf::from(dir)];
    while let Some(d) = stack.pop() {
        if CANCEL.load(Ordering::Relaxed) {
            scan.cancelled = true;
            break;
        }
        let Ok(entries) = std::fs::read_dir(&d) else {
            scan.unreadable += 1;
            continue;
        };
        for e in entries.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            let path = e.path();
            if ft.is_dir() {
                stack.push(path);
            } else if ft.is_file() && path.extension().is_some_and(|x| x.eq_ignore_ascii_case("exe")) {
                scan.files.push(ExeFile {
                    name: e.file_name().to_string_lossy().into_owned(),
                    path: path.to_string_lossy().into_owned(),
                    size: e.metadata().map(|m| m.len()).unwrap_or(0),
                });
            }
        }
    }
    scan.files.sort_by_cached_key(|f| f.path.to_lowercase());
    scan
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> windows::core::Result<T> + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| e.message())
}

fn progress(ch: Channel<Progress>) -> impl Fn(usize, usize) {
    move |done, total| {
        let _ = ch.send(Progress { done, total });
    }
}

#[tauri::command]
fn env_info() -> EnvInfo {
    EnvInfo { admin: unsafe { IsUserAnAdmin().as_bool() }, firewall_running: firewall_running() }
}

#[tauri::command]
async fn scan(dir: String) -> Result<Scan, String> {
    if !Path::new(&dir).is_dir() {
        return Err("notFolder".into());
    }
    CANCEL.store(false, Ordering::Relaxed);
    blocking(move || Ok(exe_files(&dir))).await
}

#[tauri::command]
async fn list_rules() -> Result<Vec<fw::RuleInfo>, String> {
    blocking(fw::list).await
}

#[tauri::command]
async fn block(paths: Vec<String>, on_progress: Channel<Progress>) -> Result<fw::Done, String> {
    CANCEL.store(false, Ordering::Relaxed);
    blocking(move || fw::block(&paths, &CANCEL, progress(on_progress))).await
}

#[tauri::command]
async fn unblock(paths: Option<Vec<String>>, on_progress: Channel<Progress>) -> Result<fw::Done, String> {
    CANCEL.store(false, Ordering::Relaxed);
    blocking(move || fw::unblock(paths.as_deref(), &CANCEL, progress(on_progress))).await
}

#[tauri::command]
fn cancel() {
    CANCEL.store(true, Ordering::Relaxed);
}

#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    std::process::Command::new("explorer.exe")
        .raw_arg(format!("/select,\"{path}\""))
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![env_info, scan, list_rules, block, unblock, cancel, reveal])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
