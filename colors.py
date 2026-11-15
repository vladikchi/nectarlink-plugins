#!/usr/bin/env python3
"""Only controls the external palette sidecar; never edits NectarLink settings."""
import json
import os
from pathlib import Path
import sys
import subprocess
import shutil


def main():
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    palette = config / "nectarlink/noctalia-colors.json"
    marker = palette.with_name(palette.name + ".disabled")
    command = sys.argv[1] if len(sys.argv) >= 2 else "invalid"
    if command in ("open", "send-files", "send-clipboard", "open-timeline"):
        if len(sys.argv) != 3:
            raise SystemExit("expected executable path")
        executable=sys.argv[2]
        if executable=="nectarlink-desktop":
            executable=shutil.which(executable)
            if not executable:
                raise SystemExit("nectarlink-desktop not found in PATH; set its absolute path in plugin settings")
        elif not Path(executable).is_absolute():
            raise SystemExit("expected absolute executable path or nectarlink-desktop")
        args = [executable]
        if command != "open":
            args += ["--task", command]
        subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        print(json.dumps({"launched": True}))
        return
    if len(sys.argv) != 2:
        raise SystemExit("expected one color command")
    if command not in ("status", "enable", "disable"):
        raise SystemExit("expected status, enable or disable")
    if command == "disable":
        marker.parent.mkdir(parents=True, exist_ok=True)
        # Do not follow or truncate a pre-existing file/symlink.
        try:
            fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            os.close(fd)
    elif command == "enable":
        marker.unlink(missing_ok=True)
    print(json.dumps({"enabled": not marker.exists(), "available": palette.is_file()}))


if __name__ == "__main__":
    main()
