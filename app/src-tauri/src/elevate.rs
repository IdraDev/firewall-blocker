// The UI runs unelevated (so Explorer can drop files on it); firewall changes
// go to this same exe started with --helper through UAC. The UI owns a private
// one-instance pipe and only talks to the process it launched, and vice versa.

use crate::fw::{self, Done, Request};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::hash::{BuildHasher, RandomState};
use std::io::{BufRead, BufReader, Write};
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use windows::Win32::Foundation::*;
use windows::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
use windows::Win32::System::Pipes::*;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::Shell::{SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW, ShellExecuteExW};
use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;
use windows::core::{HSTRING, PCWSTR, w};

#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum Event {
    Progress { done: usize, total: usize },
    Done(Done),
    Error { message: String },
}

struct Client {
    reader: BufReader<File>,
    writer: File,
    _process: Owned,
}

struct Owned(HANDLE);

unsafe impl Send for Owned {}

impl Drop for Owned {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

static CLIENT: Mutex<Option<Client>> = Mutex::new(None);

fn nonce() -> String {
    format!("{:016x}{:016x}", RandomState::new().hash_one(1u8), RandomState::new().hash_one(2u8))
}

// Manual-reset event the helper polls between rules; set by cancel().
fn cancel_event() -> Result<&'static (usize, String), String> {
    static EV: OnceLock<(usize, String)> = OnceLock::new();
    if let Some(ev) = EV.get() {
        return Ok(ev);
    }
    let name = format!(r"Local\FirewallBlocker-{}", nonce());
    let h = unsafe { CreateEventW(None, true, false, &HSTRING::from(&name)) }.map_err(|e| e.message())?;
    Ok(EV.get_or_init(|| (h.0 as usize, name)))
}

pub fn cancel() {
    if let Ok((h, _)) = cancel_event() {
        unsafe {
            let _ = SetEvent(HANDLE(*h as _));
        }
    }
}

pub fn running() -> bool {
    CLIENT.try_lock().map(|c| c.is_some()).unwrap_or(true)
}

fn launch_elevated(args: &str) -> Result<HANDLE, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let file = HSTRING::from(exe.as_os_str());
    let params = HSTRING::from(args);
    let mut info = SHELLEXECUTEINFOW {
        cbSize: size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        lpVerb: w!("runas"),
        lpFile: PCWSTR(file.as_ptr()),
        lpParameters: PCWSTR(params.as_ptr()),
        nShow: SW_HIDE.0,
        ..Default::default()
    };
    unsafe { ShellExecuteExW(&mut info) }.map_err(|e| {
        if e.code() == ERROR_CANCELLED.to_hresult() { "elevationCancelled".to_string() } else { e.message() }
    })?;
    Ok(info.hProcess)
}

fn connect() -> Result<Client, String> {
    let name = format!(r"\\.\pipe\FirewallBlocker-{}", nonce());
    let pipe = unsafe {
        CreateNamedPipeW(
            &HSTRING::from(&name),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            65536,
            65536,
            0,
            None,
        )
    };
    if pipe.is_invalid() {
        return Err(windows::core::Error::from_win32().message());
    }
    let file = unsafe { File::from_raw_handle(pipe.0) };
    let (_, event) = cancel_event()?;
    let process = Owned(launch_elevated(&format!("--helper {name} {event} {}", std::process::id()))?);

    // ConnectNamedPipe blocks: if the helper dies or never shows up, connect
    // to our own pipe so it returns, then the PID check below fails.
    let connected = Arc::new(AtomicBool::new(false));
    let (flag, poke, ph) = (connected.clone(), name.clone(), process.0.0 as usize);
    std::thread::spawn(move || {
        unsafe { WaitForSingleObject(HANDLE(ph as _), 20_000) };
        if !flag.load(Ordering::SeqCst) {
            let _ = OpenOptions::new().read(true).write(true).open(&poke);
        }
    });
    let res = unsafe { ConnectNamedPipe(pipe, None) };
    connected.store(true, Ordering::SeqCst);
    if let Err(e) = res {
        if e.code() != ERROR_PIPE_CONNECTED.to_hresult() {
            return Err(e.message());
        }
    }
    let mut client = 0;
    unsafe { GetNamedPipeClientProcessId(pipe, &mut client) }.map_err(|e| e.message())?;
    if client != unsafe { GetProcessId(process.0) } {
        return Err("helperFailed".into());
    }
    let reader = BufReader::new(file.try_clone().map_err(|e| e.to_string())?);
    Ok(Client { reader, writer: file, _process: process })
}

enum Fail {
    Broken(String),
    Op(String),
}

fn exchange(c: &mut Client, req: &Request, progress: fw::Progress) -> Result<Done, Fail> {
    let broken = |e: std::io::Error| Fail::Broken(e.to_string());
    let line = serde_json::to_string(req).map_err(|e| Fail::Op(e.to_string()))?;
    writeln!(c.writer, "{line}").map_err(broken)?;
    let mut buf = String::new();
    loop {
        buf.clear();
        if c.reader.read_line(&mut buf).map_err(broken)? == 0 {
            return Err(Fail::Broken("helperFailed".into()));
        }
        match serde_json::from_str::<Event>(&buf).map_err(|e| Fail::Broken(e.to_string()))? {
            Event::Progress { done, total } => progress(done, total),
            Event::Done(d) => return Ok(d),
            Event::Error { message } => return Err(Fail::Op(message)),
        }
    }
}

// UI side: starts the helper on first use (the UAC prompt), then reuses it.
pub fn request(req: &Request, progress: fw::Progress) -> Result<Done, String> {
    let mut guard = CLIENT.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        *guard = Some(connect()?);
    }
    unsafe {
        let _ = ResetEvent(HANDLE(cancel_event()?.0 as _));
    }
    match exchange(guard.as_mut().unwrap(), req, progress) {
        Ok(done) => Ok(done),
        Err(Fail::Op(e)) => Err(e),
        Err(Fail::Broken(e)) => {
            *guard = None;
            Err(e)
        }
    }
}

fn send(w: &mut File, ev: &Event) -> std::io::Result<()> {
    writeln!(w, "{}", serde_json::to_string(ev)?)
}

// Helper side: `--helper <pipe> <event> <ui pid>`. Exits when the UI closes the pipe.
pub fn serve(args: &[String]) -> i32 {
    let [pipe, event, ui] = args else { return 2 };
    let Ok(ui) = ui.parse::<u32>() else { return 2 };
    let Ok(file) = OpenOptions::new().read(true).write(true).open(pipe) else { return 3 };
    let mut server = 0;
    if unsafe { GetNamedPipeServerProcessId(HANDLE(file.as_raw_handle()), &mut server) }.is_err() || server != ui {
        return 4;
    }
    let Ok(ev) = (unsafe { OpenEventW(SYNCHRONIZATION_SYNCHRONIZE, false, &HSTRING::from(event.as_str())) }) else {
        return 5;
    };
    let cancelled = || unsafe { WaitForSingleObject(ev, 0) } == WAIT_OBJECT_0;
    let Ok(read_half) = file.try_clone() else { return 6 };
    let mut writer = file;
    for line in BufReader::new(read_half).lines() {
        let Ok(line) = line else { break };
        let reply = match serde_json::from_str::<Request>(&line) {
            Ok(req) => match fw::run(&req, &cancelled, &mut |done, total| {
                let _ = send(&mut writer, &Event::Progress { done, total });
            }) {
                Ok(done) => Event::Done(done),
                Err(e) => Event::Error { message: e.message() },
            },
            Err(e) => Event::Error { message: e.to_string() },
        };
        if send(&mut writer, &reply).is_err() {
            break;
        }
    }
    0
}
