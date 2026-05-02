from __future__ import annotations

from pathlib import Path


WORKSPACE_DIRS = ("sources", "indexes", "exports", "runs")


def ensure_pulse_dirs(root_path: str | Path) -> Path:
    root = Path(root_path).resolve()
    pulse_dir = root / ".pulse"
    pulse_dir.mkdir(parents=True, exist_ok=True)
    for name in WORKSPACE_DIRS:
        (pulse_dir / name).mkdir(parents=True, exist_ok=True)
    return pulse_dir


def workspace_db_path(root_path: str | Path) -> Path:
    return Path(root_path).resolve() / ".pulse" / "pulse.db"
