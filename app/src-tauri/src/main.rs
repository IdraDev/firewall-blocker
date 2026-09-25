#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod elevate;
mod files;
mod fw;
mod icon;

use serde::Serialize;
use std::os::windows::process::CommandExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::http::Response;
use tauri::ipc::Channel;
use windows::Win32::System::Services::*;
use windows::Win32::UI::Shell::IsUserAnAdmin;
use windows::core::w;

// One operation runs at a time (the UI disables actions while busy).
static CANCEL: AtomicBool = AtomicBool::new(false);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EnvInfo {
    admin: bool,
    helper: bool,
    firewall_running: bool,
}

#[derive(Serialize, Clone)]
struct Progress {
    done: usize,
    total: usize,
}

fn is_admin() -> bool {
    unsafe { IsUserAnAdmin().as_bool() }
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

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn env_info() -> EnvInfo {
    EnvInfo { admin: is_admin(), helper: elevate::running(), firewall_running: firewall_running() }
}

#[tauri::command]
async fn scan(dir: String) -> Result<files::Scan, String> {
    if !Path::new(&dir).is_dir() {
        return Err("notFolder".into());
    }
    CANCEL.store(false, Ordering::Relaxed);
    blocking(move || Ok(files::exe_files(&dir, &CANCEL))).await
}

#[tauri::command]
async fn inspect(paths: Vec<String>) -> Result<Vec<files::Item>, String> {
    blocking(move || Ok(files::inspect(&paths))).await
}

#[tauri::command]
async fn list_rules() -> Result<Vec<fw::RuleInfo>, String> {
    blocking(|| fw::list().map_err(|e| e.message())).await
}

// Runs in-process when the app itself is elevated, else through the helper.
#[tauri::command]
async fn apply(req: fw::Request, on_progress: Channel<Progress>) -> Result<fw::Done, String> {
    CANCEL.store(false, Ordering::Relaxed);
    blocking(move || {
        let mut progress = |done, total| {
            let _ = on_progress.send(Progress { done, total });
        };
        if is_admin() {
            fw::run(&req, &|| CANCEL.load(Ordering::Relaxed), &mut progress).map_err(|e| e.message())
        } else {
            elevate::request(&req, &mut progress)
        }
    })
    .await
}

#[tauri::command]
fn cancel() {
    CANCEL.store(true, Ordering::Relaxed);
    elevate::cancel();
}

#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    std::process::Command::new("explorer.exe")
        .raw_arg(format!("/select,\"{path}\""))
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn read_text(path: String) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|e| e.to_string())
}

#[tauri::command]
fn write_text(path: String, text: String) -> Result<(), String> {
    std::fs::write(path, text).map_err(|e| e.to_string())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--helper") {
        std::process::exit(elevate::serve(&args[2..]));
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .register_asynchronous_uri_scheme_protocol("icon", |_ctx, req, responder| {
            let path = icon::decode(req.uri().path().trim_start_matches('/'));
            std::thread::spawn(move || {
                let res = match icon::png(&path) {
                    Some(png) => Response::builder().header("Content-Type", "image/png").body(png),
                    None => Response::builder().status(404).body(Vec::new()),
                };
                responder.respond(res.expect("static response"));
            });
        })
        .invoke_handler(tauri::generate_handler![
            env_info, scan, inspect, list_rules, apply, cancel, reveal, read_text, write_text
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
