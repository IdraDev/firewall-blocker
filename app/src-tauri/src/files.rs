use crate::fw::Com;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, IPersistFile, STGM_READ};
use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};
use windows::core::{HSTRING, Interface};

#[derive(Serialize)]
pub struct ExeFile {
    name: String,
    path: String,
    size: u64,
}

#[derive(Serialize, Default)]
pub struct Scan {
    files: Vec<ExeFile>,
    unreadable: usize,
    cancelled: bool,
}

// A dropped or picked path: shortcuts resolved to their target.
#[derive(Serialize)]
pub struct Item {
    kind: &'static str,
    file: ExeFile,
}

fn is_exe(p: &Path) -> bool {
    p.extension().is_some_and(|x| x.eq_ignore_ascii_case("exe"))
}

fn exe_file(path: &Path, size: u64) -> ExeFile {
    ExeFile {
        name: path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        path: path.to_string_lossy().into_owned(),
        size,
    }
}

// Junctions and symlinks report as neither dir nor file, so they are never
// followed: no loops.
pub fn exe_files(dir: &str, cancel: &AtomicBool) -> Scan {
    let mut scan = Scan::default();
    let mut stack = vec![PathBuf::from(dir)];
    while let Some(d) = stack.pop() {
        if cancel.load(Ordering::Relaxed) {
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
            } else if ft.is_file() && is_exe(&path) {
                scan.files.push(exe_file(&path, e.metadata().map(|m| m.len()).unwrap_or(0)));
            }
        }
    }
    scan.files.sort_by_cached_key(|f| f.path.to_lowercase());
    scan
}

fn link_target(path: &str) -> Option<String> {
    unsafe {
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).ok()?;
        link.cast::<IPersistFile>().ok()?.Load(&HSTRING::from(path), STGM_READ).ok()?;
        let mut buf = [0u16; 1024];
        link.GetPath(&mut buf, std::ptr::null_mut(), 0).ok()?;
        let s = String::from_utf16_lossy(&buf[..buf.iter().position(|&c| c == 0)?]);
        (!s.is_empty()).then_some(s)
    }
}

pub fn inspect(paths: &[String]) -> Vec<Item> {
    let _com = Com::init(COINIT_APARTMENTTHREADED);
    paths
        .iter()
        .map(|p| {
            let is_link = Path::new(p).extension().is_some_and(|x| x.eq_ignore_ascii_case("lnk"));
            let path = PathBuf::from(if is_link { link_target(p).unwrap_or_else(|| p.clone()) } else { p.clone() });
            let meta = std::fs::metadata(&path).ok();
            let kind = match &meta {
                Some(m) if m.is_dir() => "folder",
                Some(m) if m.is_file() && is_exe(&path) => "exe",
                _ => "other",
            };
            Item { kind, file: exe_file(&path, meta.map(|m| m.len()).unwrap_or(0)) }
        })
        .collect()
}
