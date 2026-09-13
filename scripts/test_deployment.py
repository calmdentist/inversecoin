#!/usr/bin/env python3
"""End-to-end deployment tests on a disposable local Anvil, using only development funds."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
ZERO = "0x" + "0" * 40


def main():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    rpc = f"http://127.0.0.1:{port}"
    env = dict(os.environ, RUST_LOG="error", EXPECTED_CHAIN_ID="31337", DEPLOYER=ACCOUNT,
               INITIAL_SHARES=str(1000 * 10**18), INITIAL_QUOTE=str(1000 * 10**6),
               FEE_PPM="0", INVERSE_HOOK=ZERO, SALT_START="0")
    anvil = subprocess.Popen(["anvil", "--host", "127.0.0.1", "--port", str(port),
                              "--chain-id", "31337", "--silent"], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def request(method, params):
        payload = json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)).encode()
        req = urllib.request.Request(rpc, payload, {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result["result"]

    def run(command, config=None, ok=True):
        result = subprocess.run(command, cwd=ROOT, env=config or env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        if (result.returncode == 0) != ok:
            raise AssertionError(result.stdout)
        return result.stdout

    def send(address, signature, *args):
        return run(["cast", "send", "--rpc-url", rpc, "--unlocked", "--from", ACCOUNT,
                    "--json", address, signature, *map(str, args)])

    def nonce():
        return int(request("eth_getTransactionCount", [ACCOUNT, "latest"]), 16)

    def deploy_contract(target, *args):
        result = run(["forge", "create", "--json", "--rpc-url", rpc, "--unlocked", "--from", ACCOUNT,
                      "--broadcast", target, "--constructor-args", *args])
        return json.loads(result)["deployedTo"]

    def driver(config=None, broadcast=False, ok=True):
        command = [sys.executable, "scripts/deploy.py", "--rpc-url", rpc]
        if broadcast:
            command += ["--broadcast", "--unlocked", "--sender", ACCOUNT]
        output = run(command, config, ok)
        path = Path(re.search(r"Deployment record: (.+)", output)[1])
        return json.loads(path.read_text()), path.parent

    try:
        for attempt in range(100):
            if anvil.poll() is not None:
                raise RuntimeError("Anvil failed to start")
            try:
                request("eth_chainId", [])
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("Anvil did not become ready")

        env["POOL_MANAGER"] = deploy_contract("lib/v4-core/src/PoolManager.sol:PoolManager", ACCOUNT)
        env["QUOTE_TOKEN"] = deploy_contract("test/helpers/MockQuote.sol:MockQuote", "6")
        before = nonce()
        failed, _ = driver(broadcast=True, ok=False)
        assert failed["stage"] == "incomplete" and nonce() == before
        print("PASS insufficient seed rejected before any deployment", flush=True)

        send(env["QUOTE_TOKEN"], "mint(address,uint256)", ACCOUNT, 2200 * 10**6)
        before = nonce()
        dry, dry_dir = driver()
        assert dry["stage"] == "dry_run_only" and nonce() == before
        assert request("eth_getCode", [dry["hook"], "latest"]) == "0x"
        assert json.loads((dry_dir / "plan.json").read_text())["initialized"] is True
        print("PASS dry run simulates full liquidity initialization without broadcasting", flush=True)

        deployed, directory = driver(broadcast=True)
        assert deployed["stage"] == "verified_on_chain" and deployed["hook"] == dry["hook"]
        state = json.loads((directory / "state.json").read_text())
        assert state["initialQuote"] == state["reserveQuote"] == env["INITIAL_QUOTE"]
        assert state["initialShares"] == state["reserveShares"] == env["INITIAL_SHARES"]
        assert state["indexRay"] == str(10**27)
        receipts = json.loads((directory / "broadcast.json").read_text())
        assert len(receipts["receipts"]) == 3  # deploy, approve, initialize
        assert all(int(r["status"], 16) == 1 for r in receipts["receipts"])
        print("PASS complete deployment, real seed liquidity, archived receipts and fresh network verification", flush=True)

        before = nonce()
        again, directory = driver(broadcast=True)
        assert again["hook"] == deployed["hook"] and nonce() == before
        assert again["receipts"] == []
        assert json.loads((directory / "plan.json").read_text())["transactionsPlanned"] is False
        print("PASS rerun reuses ready market without spending gas or seeding twice", flush=True)

        send(env["QUOTE_TOKEN"], "approve(address,uint256)", deployed["gateway"], 100 * 10**6)
        send(deployed["gateway"], "buy(uint256,uint256,address,uint256)", 100 * 10**6, 0, ACCOUNT, 2**64 - 1)
        before = nonce()
        _, directory = driver(broadcast=True)
        assert nonce() == before
        state = json.loads((directory / "state.json").read_text())
        assert int(state["reserveQuote"]) == 1100 * 10**6 and int(state["indexRay"]) > 10**27
        print("PASS seeded market trades and rerun verifies changed reserves without reseeding", flush=True)

        # Simulate a previous deployment interrupted after contracts and approval, before initialize.
        partial_env = dict(env, SALT_START="1000000")
        partial = run(["forge", "script", "script/DeployInverse.s.sol:DeployInverse", "--rpc-url", rpc,
                       "--unlocked", "--sender", ACCOUNT, "--broadcast", "--slow", "-vv"], partial_env)
        partial_hook = re.search(r"  Hook (0x[0-9a-fA-F]{40})", partial)[1]
        verify_env = dict(partial_env, INVERSE_HOOK=partial_hook,
                          DEPLOYMENT_REPORT=str(directory / "must-not-pass.json"))
        run(["forge", "script", "script/VerifyInverseDeployment.s.sol:VerifyInverseDeployment",
             "--rpc-url", rpc], verify_env, ok=False)
        assert not (directory / "must-not-pass.json").exists()
        send(env["QUOTE_TOKEN"], "approve(address,uint256)", partial_hook, env["INITIAL_QUOTE"])
        before = nonce()
        resumed, directory = driver(partial_env, broadcast=True)
        assert resumed["hook"].lower() == partial_hook.lower() and nonce() == before + 1
        assert resumed["stage"] == "verified_on_chain"
        print("PASS partial deployment resumes with only initialization; unseeded verification fails", flush=True)

        before = nonce()
        driver(dict(env, EXPECTED_CHAIN_ID="46630"), broadcast=True, ok=False)
        assert nonce() == before
        driver(dict(env, INVERSE_HOOK=deployed["hook"], INITIAL_QUOTE="1000000001"),
               broadcast=True, ok=False)
        assert nonce() == before
        print("PASS wrong chain and incompatible existing configuration rejected before transactions", flush=True)
        print("All deployment scenarios passed on disposable Anvil chain 31337.", flush=True)
    finally:
        anvil.terminate()
        try:
            anvil.wait(timeout=5)
        except subprocess.TimeoutExpired:
            anvil.kill()
            anvil.wait()


if __name__ == "__main__":
    main()
