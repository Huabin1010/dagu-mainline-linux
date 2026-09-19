#!/usr/bin/env python3
"""Fetch Qualcomm public camera markdown + extract embedded images.

HTML /doc/{id}/topic/ URLs are a JS chrome shell. The text lives at
/bundle/publicresource/{document-id}/topics/{topic-name}.md
"""

from __future__ import annotations

import base64
import pathlib
import re
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1] / "docs" / "qcom-public"
IMG = ROOT / "images"

PAGES = [
    # Already archived (refresh in place)
    (
        "80-PV086-5P-camera-support.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-PV086-5P/topics/camera-support.md",
    ),
    (
        "80-88500-1-ife-clock.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/68_Camera_IFE_clock_configuration.md",
    ),
    (
        "80-88500-4-chi.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/126_CHI.md",
    ),
    (
        "80-88500-4-chi-architecture.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/127_CHI_architecture_model.md",
    ),
    (
        "80-88500-4-topology-xml.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/128_Topology_graph_XML.md",
    ),
    (
        "80-88500-4-camx.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/129_CamX.md",
    ),
    (
        "80-88500-4-spectra-480.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/124_Qualcomm_Spectra_480.md",
    ),
    # 80-88500-4 Camera parent + sibling chapters
    (
        "80-88500-4-camera.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/122_Camera.md",
    ),
    (
        "80-88500-4-capture-encode.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/123_Camera_capture_and_encode.md",
    ),
    (
        "80-88500-4-isp-tuning.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-4/topics/125_ISP_tuning_process.md",
    ),
    # 80-88500-1 sensor bring-up
    (
        "80-88500-1-sensor-driver.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/58_Camera_sensor_driver_.md",
    ),
    (
        "80-88500-1-sensor-bringup.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/camera_sensor_driver_bringup.md",
    ),
    (
        "80-88500-1-sensor-software.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/59_Sensor_software_configuration.md",
    ),
    (
        "80-88500-1-sensor-info-nodes.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/60_Sensor_information_nodes.md",
    ),
    (
        "80-88500-1-module-config.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/61_Module_configuration_.md",
    ),
    (
        "80-88500-1-sensor-hw.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/62_Sensor_hardware_configuration.md",
    ),
    (
        "80-88500-1-sensor-kernel-nodes.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/63_Sensor_kernel_nodes.md",
    ),
    (
        "80-88500-1-cci-timing.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/64_CCI_timing_and_debug.md",
    ),
    (
        "80-88500-1-cci-speed.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/65_Configure_CCI_operation_speed.md",
    ),
    (
        "80-88500-1-power-regulator.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/69_Power_regulator_configuration.md",
    ),
    (
        "80-88500-1-clock.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/70_Clock_configuration.md",
    ),
    (
        "80-88500-1-cci-master.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/71_CCI_master_index_configuration.md",
    ),
    (
        "80-88500-1-cam-res-mgr.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/72_Camera_resource_manager_configuration.md",
    ),
    (
        "80-88500-1-sensor-library.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-1/topics/73_Sensor_library_configuration.md",
    ),
    # QRB5165 HW routing
    (
        "80-PV086-5P-dphy-routing.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-PV086-5P/topics/mipi-csi-d-phy-routing-constraints-up-to-2dot5-Gbps.md",
    ),
    # C-PHY routing: markdown endpoint returns HTTP 403 (login / export).
    # HTML shell is public; do not treat 403 as a fetch success.
    # Qualcomm Linux Camera Guide (upstream CamSS / V4L2)
    (
        "80-70015-17-v4l2.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-70015-17/topics/v4l2_interface.md",
    ),
    (
        "80-70020-17-camera-overview.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-70020-17/topics/camera-overview.md",
    ),
    (
        "80-70020-17-stream-cameras.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-70020-17/topics/stream-cameras.md",
    ),
    (
        "80-70030-17-troubleshoot.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-70030-17/topics/troubleshooting.md",
    ),
    # 80-80022-17 stream-cameras.md is 1.4MB QCS GStreamer; keep the
    # hand-trimmed V4L2/CAMSS excerpt, do not auto-fetch the full page.
    # QCS9075 offline IFE / QMMF UBWC: archive only, not dagu PIX dest
    (
        "80-70022-17-offline-ife.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-70022-17/topics/support-multi-camera-using-offline-IFE.md",
    ),
    (
        "80-88500-3-ubwc.md",
        "https://docs.qualcomm.com/bundle/publicresource/80-88500-3/topics/61_UBWC_control_use_cases.md",
    ),
]

PLAIN = [
    (
        "kernel-qcom-camss.html",
        "https://www.kernel.org/doc/html/latest/admin-guide/media/qcom_camss.html",
    ),
    (
        "qcom-sm8250-camss.yaml",
        "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/Documentation/devicetree/bindings/media/qcom,sm8250-camss.yaml",
    ),
    (
        "cam_isp_ife.h",
        "https://raw.githubusercontent.com/StatiXOS/android_hardware_qcom-caf_kernel-headers/f2c161d0372a939ef5598ba254f815be8dcf145a/msm-4.19/media/cam_isp_ife.h",
    ),
    (
        "cam_vfe_bus_ver3.c",
        "https://raw.githubusercontent.com/LineageOS/android_kernel_xiaomi_sm8250/lineage-18.1/techpack/camera/drivers/cam_isp/isp_hw_mgr/isp_hw/vfe_hw/vfe_bus/cam_vfe_bus_ver3.c",
    ),
]

IMG_RE = re.compile(
    r"!\[([^\]]*)\]\(data:image/(png|jpeg|jpg|gif|webp);base64,([A-Za-z0-9+/=\n\r]+)\)",
    re.I,
)


def opener() -> urllib.request.OpenerDirector:
    o = urllib.request.build_opener()
    o.addheaders = [
        ("User-Agent", "Mozilla/5.0 (compatible; dagu-docs-archive/1.0)"),
        ("Accept", "text/markdown, text/plain, text/html, */*"),
    ]
    return o


def sniff_ext(declared: str, blob: bytes) -> str:
    if blob.startswith(b"RIFF") and b"WEBP" in blob[:16]:
        return "webp"
    if blob.startswith(b"\x89PNG"):
        return "png"
    if blob.startswith(b"\xff\xd8"):
        return "jpg"
    ext = declared.lower()
    if ext == "jpeg":
        return "jpg"
    return ext


def fetch_markdown(handle: urllib.request.OpenerDirector, fname: str, url: str) -> None:
    print(f"GET {url}")
    with handle.open(url, timeout=90) as resp:
        text = resp.read().decode("utf-8", errors="replace")
    stem = pathlib.Path(fname).stem
    counter = [0]

    def repl(match: re.Match[str], stem: str = stem, counter: list[int] = counter) -> str:
        counter[0] += 1
        alt = match.group(1) or f"fig{counter[0]}"
        blob = base64.b64decode(re.sub(r"\s+", "", match.group(3)))
        ext = sniff_ext(match.group(2), blob)
        imgname = f"{stem}-{counter[0]:02d}.{ext}"
        (IMG / imgname).write_bytes(blob)
        print(f"  image {imgname} {len(blob)} bytes")
        return f"![{alt}](images/{imgname})"

    out = ROOT / fname
    out.write_text(IMG_RE.sub(repl, text), encoding="utf-8")
    print(f"  wrote {out} {out.stat().st_size} bytes images={counter[0]}")


def fetch_plain(handle: urllib.request.OpenerDirector, fname: str, url: str) -> None:
    print(f"GET {url}")
    with handle.open(url, timeout=90) as resp:
        data = resp.read()
    out = ROOT / fname
    out.write_bytes(data)
    print(f"  wrote {out} {out.stat().st_size} bytes")


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    IMG.mkdir(exist_ok=True)
    handle = opener()
    failed: list[str] = []
    for fname, url in PAGES:
        try:
            fetch_markdown(handle, fname, url)
        except Exception as exc:  # noqa: BLE001 — record and continue
            print(f"  FAIL {fname}: {exc}")
            failed.append(f"{fname}: {exc}")
    for fname, url in PLAIN:
        try:
            fetch_plain(handle, fname, url)
        except Exception as exc:  # noqa: BLE001
            print(f"  FAIL {fname}: {exc}")
            failed.append(f"{fname}: {exc}")
    if failed:
        raise SystemExit("failed:\n" + "\n".join(failed))
    print("done")


if __name__ == "__main__":
    main()
