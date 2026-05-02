from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    project_root: Path
    pulse_root: Path
    db_path: Path

    @classmethod
    def load(cls) -> "Settings":
        project_root = Path(os.getenv("PULSE_HOME", Path.cwd())).resolve()
        pulse_root = project_root / ".pulse"
        return cls(
            project_root=project_root,
            pulse_root=pulse_root,
            db_path=pulse_root / "pulse.db",
        )


settings = Settings.load()
