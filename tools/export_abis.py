#!/usr/bin/env python3
"""Export or verify compiler-generated contract ABIs; requires Python 3 and Forge only."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true", help="fail if delivered ABIs differ from the compiler")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]

for name in ("MAXT", "MaxTxHook"):
    result = subprocess.run(
        ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    abi = json.loads(result.stdout)
    path = root / "docs" / "abi" / f"{name}.json"
    if args.check:
        if not path.exists() or json.loads(path.read_text()) != abi:
            raise SystemExit(f"ABI mismatch: {path.relative_to(root)}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(abi, indent=2) + "\n")
    print(f"{'Checked' if args.check else 'Exported'} {path.relative_to(root)}")
