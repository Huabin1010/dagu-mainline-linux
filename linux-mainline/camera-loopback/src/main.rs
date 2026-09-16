//! dagu camera loopback: libcamera Viewfinder → YUYV /dev/video20/21.
//! SoftISP stays on CPU 0–3. No GStreamer. No spa-libcamera.

use std::ffi::{c_char, CString};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const FRONT_DEV: &str = "/dev/video20";
const REAR_DEV: &str = "/dev/video21";
const FRONT_ID: &str = "/base/soc@0/cci@ac50000/i2c-bus@1/camera@10";
const REAR_ID: &str = "/base/soc@0/cci@ac4f000/i2c-bus@0/camera@10";
const FRONT_W: u32 = 1296;
const FRONT_H: u32 = 976;
const REAR_W: u32 = 1020;
const REAR_H: u32 = 764;
const RESET: &str = "/usr/local/sbin/dagu-camss-graph-reset.sh";
const BIN: &str = "/usr/local/sbin/dagu-camera-loopback";

#[link(name = "dagu_cam", kind = "static")]
#[allow(dead_code)]
extern "C" {
    fn dagu_pin_cpu_0_3();
    fn dagu_pin_all_threads();
    fn dagu_stamp_loopback(dev: *const c_char, w: u32, h: u32) -> i32;
    fn dagu_pipe_start(
        slot: i32,
        camera_id: *const c_char,
        loopback_dev: *const c_char,
        w: u32,
        h: u32,
    ) -> i32;
    fn dagu_pipe_stop(slot: i32);
    fn dagu_pipe_running(slot: i32) -> i32;
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("cstr")
}

fn comm(pid: &str) -> String {
    fs::read_to_string(format!("/proc/{pid}/comm"))
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn is_camera_client(name: &str) -> bool {
    name == "pipewire"
        || name == "pipewire-pulse"
        || name.starts_with("snapshot")
        || name.starts_with("chrome")
        || name.starts_with("chromium")
        || name == "firefox"
        || name.starts_with("WebKit")
}

fn pid_holds(pid: &str, dev: &str) -> bool {
    let fd_dir = format!("/proc/{pid}/fd");
    let Ok(fds) = fs::read_dir(&fd_dir) else {
        return false;
    };
    for fd in fds.flatten() {
        if let Ok(target) = fs::read_link(fd.path()) {
            if target.as_os_str().as_bytes() == dev.as_bytes() {
                return true;
            }
        }
    }
    false
}

fn holds(dev: &str, skip_pid: u32) -> bool {
    let Ok(procs) = fs::read_dir("/proc") else {
        return false;
    };
    for ent in procs.flatten() {
        let pid = ent.file_name();
        let Some(pid) = pid.to_str() else { continue };
        if !pid.as_bytes().iter().all(|b| b.is_ascii_digit()) {
            continue;
        }
        if pid.parse::<u32>().ok() == Some(skip_pid) {
            continue;
        }
        let name = comm(pid);
        if !is_camera_client(&name) {
            continue;
        }
        if pid_holds(pid, dev) {
            return true;
        }
    }
    false
}

fn camss_reset() {
    if Path::new(RESET).is_file() {
        let _ = Command::new(RESET).status();
    }
}

fn stamp(dev: &str, w: u32, h: u32) {
    let d = cstr(dev);
    unsafe {
        dagu_stamp_loopback(d.as_ptr(), w, h);
    }
}

fn child_alive(kid: &mut Option<Child>) -> bool {
    match kid {
        None => false,
        Some(ch) => match ch.try_wait() {
            Ok(None) => true,
            Ok(Some(st)) => {
                eprintln!("dagu-camera-loopback: SoftISP child exited {st}");
                *kid = None;
                false
            }
            Err(e) => {
                eprintln!("dagu-camera-loopback: try_wait: {e}");
                *kid = None;
                false
            }
        },
    }
}

fn kill_child(kid: &mut Option<Child>) {
    if let Some(mut ch) = kid.take() {
        let pid = ch.id();
        /* SIGKILL: libcamera IPA asserts on stop() and must not take watch down. */
        let _ = ch.kill();
        let _ = ch.wait();
        eprintln!("dagu-camera-loopback: killed SoftISP pid {pid}");
    }
}

fn spawn_slot(slot: i32) -> Option<Child> {
    let arg = if slot == 0 { "front" } else { "rear" };
    match Command::new(BIN)
        .arg(arg)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(c) => {
            eprintln!("dagu-camera-loopback: spawn {arg} pid {}", c.id());
            Some(c)
        }
        Err(e) => {
            eprintln!("dagu-camera-loopback: spawn {arg}: {e}");
            None
        }
    }
}

fn ensure_slot(slot: i32, kids: &mut [Option<Child>; 2]) {
    let other = 1 - slot as usize;
    let me = slot as usize;
    if child_alive(&mut kids[other]) {
        kill_child(&mut kids[other]);
        camss_reset();
        if slot == 0 {
            stamp(REAR_DEV, REAR_W, REAR_H);
        } else {
            stamp(FRONT_DEV, FRONT_W, FRONT_H);
        }
    }
    if child_alive(&mut kids[me]) {
        return;
    }
    camss_reset();
    kids[me] = spawn_slot(slot);
}

fn watch() -> ! {
    let self_pid = std::process::id();
    unsafe {
        dagu_pin_cpu_0_3();
    }
    /* Do not restart WirePlumber here. Killing it drops Snapshot's PW target. */
    stamp(FRONT_DEV, FRONT_W, FRONT_H);
    stamp(REAR_DEV, REAR_W, REAR_H);
    eprintln!("dagu-camera-loopback: rust watch on CPU 0-3 (SoftISP in child, SIGKILL on idle)");

    let mut kids: [Option<Child>; 2] = [None, None];
    let mut idle_since: Option<Instant> = None;
    let idle = Duration::from_millis(800);
    let mut hw = false;

    loop {
        let want_front = holds(FRONT_DEV, self_pid);
        let want_rear = holds(REAR_DEV, self_pid);

        if want_rear {
            idle_since = None;
            ensure_slot(1, &mut kids);
            hw = true;
        } else if want_front {
            idle_since = None;
            ensure_slot(0, &mut kids);
            hw = true;
        } else {
            if idle_since.is_none() {
                idle_since = Some(Instant::now());
            }
            if idle_since.unwrap().elapsed() >= idle {
                let had = kids[0].is_some() || kids[1].is_some();
                kill_child(&mut kids[0]);
                kill_child(&mut kids[1]);
                if had || hw {
                    camss_reset();
                    stamp(FRONT_DEV, FRONT_W, FRONT_H);
                    stamp(REAR_DEV, REAR_W, REAR_H);
                    eprintln!("dagu-camera-loopback: idle, CAMSS graph reset");
                    hw = false;
                }
            }
        }
        /* Do not walk /proc/self/task every tick: idle watch was ~25% CPU
         * and the fd scan races Cursor's thousands of fds. SoftISP child
         * pins itself. */
        thread::sleep(Duration::from_millis(if hw { 250 } else { 400 }));
    }
}

fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_else(|| "watch".into());
    match cmd.as_str() {
        "watch" | "" => watch(),
        "front" => {
            unsafe {
                /* Inherit watch cgroup (CPU 0-5). Pinning 0-3 here births
                 * SWIspWorker on A55 and the preview drops to ~11 fps. */
                let id = cstr(FRONT_ID);
                let dev = cstr(FRONT_DEV);
                if dagu_pipe_start(0, id.as_ptr(), dev.as_ptr(), FRONT_W, FRONT_H) != 0 {
                    std::process::exit(1);
                }
            }
            loop {
                thread::sleep(Duration::from_secs(60));
            }
        }
        "rear" => {
            unsafe {
                let id = cstr(REAR_ID);
                let dev = cstr(REAR_DEV);
                if dagu_pipe_start(1, id.as_ptr(), dev.as_ptr(), REAR_W, REAR_H) != 0 {
                    std::process::exit(1);
                }
            }
            loop {
                thread::sleep(Duration::from_secs(60));
            }
        }
        _ => {
            eprintln!("usage: dagu-camera-loopback [watch|front|rear]");
            std::process::exit(2);
        }
    }
}
