#!/usr/bin/env python3
"""Run the full Foundry deployment, then verify network state and archive public receipts."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(command, env):
    # No shell interpolation; Foundry loads .env and manages wallet signing itself.
    subprocess.run(command, cwd=ROOT, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", default="robinhood", help="Foundry RPC alias or URL")
    parser.add_argument("--broadcast", action="store_true", help="Send deployment and seed transactions")
    signer = parser.add_mutually_exclusive_group()
    signer.add_argument("--account", help="Foundry keystore name")
    signer.add_argument("--ledger", action="store_true")
    signer.add_argument("--trezor", action="store_true")
    signer.add_argument("--unlocked", action="store_true", help="Use an RPC-managed development account")
    parser.add_argument("--sender", help="Optional signing address (DEPLOYER is required in .env)")
    args = parser.parse_args()
    if args.broadcast and not any((args.account, args.ledger, args.trezor, args.unlocked)):
        parser.error("--broadcast requires --account, --ledger, --trezor, or --unlocked")
    if not shutil.which("forge"):
        parser.error("Foundry forge is required")

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    output = ROOT / "artifacts" / "deployments" / stamp
    output.mkdir(parents=True)
    plan = output / "plan.json"
    env = os.environ.copy()
    env["DEPLOYMENT_REPORT"] = str(plan)
    # Foundry does the wallet prompting; the driver never reads keys or passwords.
    command = ["forge", "script", "script/DeployInverseFull.s.sol:DeployInverseFull",
               "--rpc-url", args.rpc_url, "-vv"]
    if args.account:
        command += ["--account", args.account]
    for flag in ("ledger", "trezor", "unlocked"):
        if getattr(args, flag):
            command.append("--" + flag)
    if args.sender:
        command += ["--sender", args.sender]
    if args.broadcast:
        command += ["--broadcast", "--slow"]

    result = {"stage": "started", "broadcastRequested": args.broadcast, "createdAtUtc": stamp,
              "plan": str(plan.relative_to(ROOT)), "receipts": []}
    success = False
    try:
        run(command, env)
        deployment = json.loads(plan.read_text())
        result.update(chainId=deployment["chainId"], hook=deployment["hook"],
                      token=deployment["token"], gateway=deployment["gateway"])
        if args.broadcast:
            state = output / "state.json"
            env["INVERSE_HOOK"] = deployment["hook"]
            env["DEPLOYMENT_REPORT"] = str(state)
            run(["forge", "script", "script/VerifyInverseDeployment.s.sol:VerifyInverseDeployment",
                 "--rpc-url", args.rpc_url, "-vv"], env)
            verified = json.loads(state.read_text())
            if verified["stage"] != "verified_on_chain" or verified["hook"] != deployment["hook"]:
                raise ValueError("network-state verification report mismatch")
            result.update(stage="verified_on_chain", state=str(state.relative_to(ROOT)))
            if deployment["transactionsPlanned"]:
                receipt = (ROOT / "broadcast" / "DeployInverseFull.s.sol" /
                           str(deployment["chainId"]) / "run-latest.json")
                if not receipt.is_file():
                    raise ValueError("broadcast receipt file missing; network state was verified")
                archived = output / "broadcast.json"
                shutil.copy2(receipt, archived)
                result["receipts"].append(str(archived.relative_to(ROOT)))
        else:
            result["stage"] = "dry_run_only"
        success = True
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError, KeyboardInterrupt) as error:
        # Do not print CalledProcessError's command: RPC URLs may contain credentials.
        result["stage"] = "incomplete" if args.broadcast else "dry_run_failed"
        print("Deployment did not finish. Inspect the Foundry output above.", file=sys.stderr)
        if isinstance(error, (OSError, ValueError, KeyError)):
            print(str(error), file=sys.stderr)
        if args.broadcast:
            print("Some transactions may have landed. Rerun the same configuration to finish safely; "
                  "keep Foundry's broadcast/ receipts.", file=sys.stderr)
    finally:
        # Preserve a usable address record even when broadcasting stopped after simulation.
        if plan.is_file():
            try:
                planned = json.loads(plan.read_text())
                result.update(chainId=planned["chainId"], hook=planned["hook"],
                              token=planned["token"], gateway=planned["gateway"])
            except (OSError, ValueError, KeyError):
                pass
        manifest = output / "manifest.json"
        manifest.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Deployment record: {manifest}", flush=True)
    if success:
        print("Market is deployed, seeded, and verified on the network." if args.broadcast
              else "Dry run passed. No transactions sent. Add --broadcast to deploy and seed.")
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
