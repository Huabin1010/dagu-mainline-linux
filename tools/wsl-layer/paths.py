from __future__ import annotations

import json
from pathlib import Path

# tools/wsl-layer/paths.py -> repo root is parents[2]
REPO_ROOT = Path(__file__).resolve().parents[2]
LAYER_DIR = REPO_ROOT / ".wsl-layer"
STATE_FILE = LAYER_DIR / "state.json"
LIVE_LOG = LAYER_DIR / "live.log"
CONFIG_FILE = REPO_ROOT / "wsl-layer.json"
DEFAULT_PORT = 19627
DEFAULT_WSL_WORKSPACE = "~/projects/xiaomi-pad870-win11-arm"


def ensure_layer_dir() -> Path:
    LAYER_DIR.mkdir(parents=True, exist_ok=True)
    return LAYER_DIR


def load_config() -> dict:
    defaults = {
        "host": "127.0.0.1",
        "port": DEFAULT_PORT,
        "wsl_distro": None,
        "wsl_workspace": DEFAULT_WSL_WORKSPACE,
        "initial_cwd": DEFAULT_WSL_WORKSPACE,
        "shell": "bash -l",
    }
    if CONFIG_FILE.is_file():
        with CONFIG_FILE.open("r", encoding="utf-8") as f:
            user = json.load(f)
        defaults.update({k: v for k, v in user.items() if v is not None})

    workspace = defaults.get("wsl_workspace") or DEFAULT_WSL_WORKSPACE
    cwd = defaults.get("initial_cwd") or workspace
    if cwd.startswith("/mnt/") or _is_win_drive_path(cwd):
        cwd = workspace
    defaults["wsl_workspace"] = workspace
    defaults["initial_cwd"] = cwd
    return defaults


def _is_win_drive_path(path: str) -> bool:
    return len(path) >= 3 and path[1] == ":" and path[2] in ("/", "\\")


def load_state() -> dict | None:
    if not STATE_FILE.is_file():
        return None
    try:
        with STATE_FILE.open("r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def save_state(state: dict) -> None:
    ensure_layer_dir()
    with STATE_FILE.open("w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


def clear_state() -> None:
    if STATE_FILE.is_file():
        STATE_FILE.unlink()
