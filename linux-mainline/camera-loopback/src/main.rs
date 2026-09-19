//! dagu camera loopback: libcamera Viewfinder → YUYV /dev/video20/21.
//! SoftISP stays on CPU 0–3. No GStreamer. No spa-libcamera.

use std::ffi::{c_char, CString};
use std::fs::{self, File};
use std::os::fd::FromRawFd;
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
/* xcast / Qt v4l2 reject 1296×976. SoftISP still skip-sizes; pack scales. */
const LOOP_W: u32 = 1280;
const LOOP_H: u32 = 720;
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

fn skip_fd_scan(name: &str) -> bool {
    /* These never hold /dev/video20/21 as a V4L2 capture client, but
     * their fd tables are huge. Walking gnome-shell/Xwayland every
     * tick was 69% CPU idle and starved sshd into a wedged session. */
    name.starts_with("dagu-camera")
        || name.starts_with("cursor")
        || name.starts_with("Cursor")
        || name == "gnome-shell"
        || name.starts_with("mutter")
        || name.starts_with("Xwayland")
        || name == "Xorg"
        || name.starts_with("sshd")
        || name.starts_with("systemd")
        || name.starts_with("dbus-")
        || name == "gjs"
}

fn pid_holds_any(pid: &str, front: bool, rear: bool) -> (bool, bool) {
    if !front && !rear {
        return (false, false);
    }
    let fd_dir = format!("/proc/{pid}/fd");
    let Ok(fds) = fs::read_dir(&fd_dir) else {
        return (false, false);
    };
    let mut got_f = false;
    let mut got_r = false;
    for fd in fds.flatten() {
        let Ok(target) = fs::read_link(fd.path()) else { continue };
        let b = target.as_os_str().as_bytes();
        if front && !got_f && b == FRONT_DEV.as_bytes() {
            got_f = true;
        }
        if rear && !got_r && b == REAR_DEV.as_bytes() {
            got_r = true;
        }
        if got_f == front && got_r == rear {
            break;
        }
    }
    (got_f, got_r)
}

/* One /proc walk for both nodes. Previous code scanned twice. */
fn client_holds(skip_pid: u32, cached: &[(String, String)]) -> (bool, bool) {
    let mut want_f = false;
    let mut want_r = false;
    for (pid, name) in cached {
        if want_f && want_r {
            break;
        }
        if pid.parse::<u32>().ok() == Some(skip_pid) {
            continue;
        }
        if skip_fd_scan(name) {
            continue;
        }
        let (f, r) = pid_holds_any(pid, !want_f, !want_r);
        want_f |= f;
        want_r |= r;
    }
    (want_f, want_r)
}

fn refresh_user_pids() -> Vec<(String, String)> {
    let mut out = Vec::new();
    let Ok(procs) = fs::read_dir("/proc") else {
        return out;
    };
    for ent in procs.flatten() {
        let pid = ent.file_name();
        let Some(pid) = pid.to_str() else { continue };
        if !pid.as_bytes().iter().all(|b| b.is_ascii_digit()) {
            continue;
        }
        if fs::read_link(format!("/proc/{pid}/exe")).is_err() {
            continue;
        }
        let name = comm(pid);
        if skip_fd_scan(&name) {
            continue;
        }
        out.push((pid.to_string(), name));
    }
    out
}

fn camss_reset() {
    if Path::new(RESET).is_file() {
        let _ = Command::new(RESET).status();
    }
}

fn stamp_hold(dev: &str, w: u32, h: u32) -> Option<File> {
    let d = cstr(dev);
    let fd = unsafe { dagu_stamp_loopback(d.as_ptr(), w, h) };
    if fd < 0 {
        eprintln!("dagu-camera-loopback: stamp {dev} failed");
        None
    } else {
        /* SAFETY: dagu_stamp_loopback returns a new open fd or -1. */
        Some(unsafe { File::from_raw_fd(fd) })
    }
}

fn restamp(holds: &mut [Option<File>; 2], slot: usize) {
    holds[slot] = None;
    let (dev, w, h) = if slot == 0 {
        (FRONT_DEV, LOOP_W, LOOP_H)
    } else {
        (REAR_DEV, LOOP_W, LOOP_H)
    };
    holds[slot] = stamp_hold(dev, w, h);
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

fn ensure_slot(
    slot: i32,
    kids: &mut [Option<Child>; 2],
    holds: &mut [Option<File>; 2],
    other_held: bool,
) {
    let other = 1 - slot as usize;
    let me = slot as usize;
    if child_alive(&mut kids[other]) {
        kill_child(&mut kids[other]);
        camss_reset();
        /* xcast keeps the outgoing node mmap'd during an in-app
         * switch. restamp S_FMT would EBUSY or tear that queue. */
        if !other_held {
            restamp(holds, other);
        }
    }
    if child_alive(&mut kids[me]) {
        return;
    }
    /* Drop gray hold then spawn. Child open_loop writes gray before
     * libcamera STREAMON; camss_reset here would starve xcast DQBUF. */
    holds[me] = None;
    kids[me] = spawn_slot(slot);
}

fn watch() -> ! {
    let self_pid = std::process::id();
    unsafe {
        dagu_pin_cpu_0_3();
    }
    /* Do not restart WirePlumber here. Killing it drops Snapshot's PW target. */
    let mut hold_fds: [Option<File>; 2] = [None, None];
    restamp(&mut hold_fds, 0);
    restamp(&mut hold_fds, 1);
    eprintln!("dagu-camera-loopback: rust watch YUYV {LOOP_W}x{LOOP_H} hold-fd (SoftISP child, SIGKILL on idle)");

    let mut kids: [Option<Child>; 2] = [None, None];
    let mut idle_since: Option<Instant> = None;
    let idle = Duration::from_millis(800);
    let mut hw = false;
    let mut prev_front = false;
    let mut prev_rear = false;
    let mut pid_cache: Vec<(String, String)> = Vec::new();
    let mut pid_cache_at = Instant::now() - Duration::from_secs(8);

    loop {
        if pid_cache_at.elapsed() >= Duration::from_secs(2) {
            pid_cache = refresh_user_pids();
            pid_cache_at = Instant::now();
        }
        let (want_front, want_rear) = client_holds(self_pid, &pid_cache);

        if want_front || want_rear {
            idle_since = None;
            /* In-app switch opens the new node before closing the
             * old one. Prefer the newly appeared fd so front is not
             * starved while rear is still held. */
            let slot = if want_front && want_rear {
                if want_front && !prev_front {
                    0
                } else if want_rear && !prev_rear {
                    1
                } else if child_alive(&mut kids[0]) {
                    0
                } else {
                    1
                }
            } else if want_rear {
                1
            } else {
                0
            };
            let other_held = if slot == 0 { want_rear } else { want_front };
            ensure_slot(slot, &mut kids, &mut hold_fds, other_held);
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
                    restamp(&mut hold_fds, 0);
                    restamp(&mut hold_fds, 1);
                    eprintln!("dagu-camera-loopback: idle, CAMSS graph reset");
                    hw = false;
                }
            }
        }
        prev_front = want_front;
        prev_rear = want_rear;
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
