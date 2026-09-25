// Program icons served as PNG at http://icon.localhost/<url-encoded path>.

use crate::fw::Com;
use std::path::Path;
use std::sync::Mutex;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Storage::FileSystem::FILE_ATTRIBUTE_NORMAL;
use windows::Win32::System::Com::COINIT_APARTMENTTHREADED;
use windows::Win32::UI::Shell::{SHFILEINFOW, SHGFI_FLAGS, SHGFI_ICON, SHGFI_LARGEICON, SHGFI_USEFILEATTRIBUTES, SHGetFileInfoW};
use windows::Win32::UI::WindowsAndMessaging::{DestroyIcon, GetIconInfo, HICON, ICONINFO};
use windows::core::HSTRING;

pub fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match (b[i], s.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok())) {
            (b'%', Some(v)) => {
                out.push(v);
                i += 3;
            }
            (c, _) => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

// BGRA pixels of the icon's color bitmap; icons without alpha take it from the mask.
unsafe fn pixels(icon: HICON) -> Option<(u32, u32, Vec<u8>)> {
    unsafe {
        let mut ii = ICONINFO::default();
        GetIconInfo(icon, &mut ii).ok()?;
        let mut bm = BITMAP::default();
        GetObjectW(ii.hbmColor.into(), size_of::<BITMAP>() as i32, Some(&mut bm as *mut _ as _));
        let (w, h) = (bm.bmWidth, bm.bmHeight);
        let dc = CreateCompatibleDC(None);
        let read = |bmp: HBITMAP| {
            let mut bi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut buf = vec![0u8; (w * h * 4).max(0) as usize];
            GetDIBits(dc, bmp, 0, h as u32, Some(buf.as_mut_ptr() as _), &mut bi, DIB_RGB_COLORS);
            buf
        };
        let mut px = if w > 0 && h > 0 { read(ii.hbmColor) } else { Vec::new() };
        if !px.is_empty() && px.chunks(4).all(|p| p[3] == 0) {
            let mask = read(ii.hbmMask);
            for (p, m) in px.chunks_mut(4).zip(mask.chunks(4)) {
                p[3] = if m[0] == 0 { 255 } else { 0 };
            }
        }
        let _ = DeleteDC(dc);
        let _ = DeleteObject(ii.hbmColor.into());
        let _ = DeleteObject(ii.hbmMask.into());
        (!px.is_empty()).then(|| {
            px.chunks_mut(4).for_each(|p| p.swap(0, 2));
            (w as u32, h as u32, px)
        })
    }
}

fn encode(w: u32, h: u32, rgba: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().ok()?.write_image_data(rgba).ok()?;
    Some(out)
}

// Missing programs (orphaned rules) get the generic .exe icon. Serialized:
// SHGetFileInfo fails for a good share of calls when many threads race.
pub fn png(path: &str) -> Option<Vec<u8>> {
    static LOCK: Mutex<()> = Mutex::new(());
    let _one = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _com = Com::init(COINIT_APARTMENTTHREADED);
    let flags = if Path::new(path).exists() { SHGFI_FLAGS(0) } else { SHGFI_USEFILEATTRIBUTES };
    let mut info = SHFILEINFOW::default();
    unsafe {
        let ok = SHGetFileInfoW(
            &HSTRING::from(path),
            FILE_ATTRIBUTE_NORMAL,
            Some(&mut info),
            size_of::<SHFILEINFOW>() as u32,
            SHGFI_ICON | SHGFI_LARGEICON | flags,
        );
        if ok == 0 || info.hIcon.is_invalid() {
            return None;
        }
        let px = pixels(info.hIcon);
        let _ = DestroyIcon(info.hIcon);
        let (w, h, rgba) = px?;
        encode(w, h, &rgba)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn decode_percent_utf8() {
        assert_eq!(super::decode("C%3A%5CGiochi%5C%C3%A0%20b.exe"), r"C:\Giochi\à b.exe");
        assert_eq!(super::decode("100%"), "100%");
    }

    #[test]
    fn notepad_icon_is_png() {
        let png = super::png(r"C:\Windows\System32\notepad.exe").unwrap();
        assert_eq!(&png[1..4], b"PNG");
        assert!(super::png(r"C:\nope\missing.exe").is_some());
    }
}
