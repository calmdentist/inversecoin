#!/usr/bin/env python3
"""Generate Kyber fixtures from execution of the pinned routed candidate.

No RPC, signing key or deployment is involved. Requires the repository's pinned
Foundry/dependencies. The output belongs in the separate kyberswap-dex-lib repo.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((ROOT / "releases/routed-candidate/manifest.json").read_text())
    for relative, expected in manifest["sourcesSha256"].items():
        actual = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"Reviewed source/config changed: {relative}; review before regenerating")
    artifacts = ROOT / "artifacts"
    artifacts.mkdir(exist_ok=True)
    # Only this generator's previous output, never wallet/deployment artifacts.
    for group in ("normal", "inverse0"):
        for path in artifacts.glob(f"kyber-vector-{group}-*.json"):
            if path.stem.rsplit("-", 1)[-1].isdigit():
                path.unlink()
    subprocess.run(
        ["forge", "test", "--match-path", "test/RoutedKyberVectors.t.sol", "--match-test", "testExport"],
        cwd=ROOT, check=True,
    )
    cases = []
    for group in ("inverse0", "normal"):
        paths = sorted(artifacts.glob(f"kyber-vector-{group}-*.json"), key=lambda p: int(p.stem.rsplit("-", 1)[1]))
        if len(paths) != 116:
            raise SystemExit(f"Incomplete fixture export: {group} has {len(paths)}, expected 116")
        for path in paths:
            case = json.loads(path.read_text())
            case["name"] = path.stem.removeprefix("kyber-vector-")
            cases.append(case)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("[\n" + ",\n".join(json.dumps(c, separators=(",", ":"), sort_keys=True) for c in cases) + "\n]\n")
    print(f"Exported {len(cases)} cases ({sum(c['success'] for c in cases)} successful executions) to {args.output}")


if __name__ == "__main__":
    main()
