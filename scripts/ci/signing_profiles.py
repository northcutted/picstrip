#!/usr/bin/env python3
"""Remove only provisioning profiles introduced by this ephemeral signing job."""
import json
import os
from pathlib import Path
import sys

roots = [Path.home() / "Library/MobileDevice/Provisioning Profiles",
         Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]
snapshot = Path(os.environ["RUNNER_TEMP"]) / "picstrip-profile-baseline.json"
current = {str(p) for root in roots for p in root.glob("*.mobileprovision")}
if sys.argv[1] == "record":
    snapshot.write_text(json.dumps(sorted(current)))
elif sys.argv[1] == "cleanup" and snapshot.is_file():
    for name in current - set(json.loads(snapshot.read_text())):
        Path(name).unlink()
else:
    raise SystemExit("Expected record or cleanup with an existing baseline")
