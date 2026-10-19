#!/usr/bin/env python3
"""Launch a keyless loopback Anvil fork and run actual-runtime Forge tests; NEVER broadcast.
Public RPC is pruned: use latest by default. --block needs archive state when old.
"""
import argparse
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import time
from readiness_rpc import NETWORKS, UA, rpc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--block', type=int)
    parser.add_argument('--match-test', help='Optional focused rehearsal test name')
    parser.add_argument('--trace', action='store_true', help='Retain full local call/event traces')
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    url, chain, _ = NETWORKS['robinhood']
    if int(rpc(url, 'eth_chainId', []), 16) != chain:
        raise SystemExit('wrong source chain')
    block = args.block or int(rpc(url, 'eth_blockNumber', []), 16)
    header = rpc(url, 'eth_getBlockByNumber', [hex(block), False])
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    local = f'http://127.0.0.1:{port}'
    manifest = {'sourceRPC': url, 'chainId': chain, 'forkBlock': block, 'blockHash': header['hash'],
        'localURL': local, 'broadcast': False, 'accounts': 0,
        'limits': 'Factory deployer impersonated; synthetic attestation; IMD balances injected only inside Forge. Not source admission.'}
    (args.out / 'fork.json').write_text(json.dumps(manifest, indent=2) + '\n')
    with (args.out / 'anvil.log').open('w') as log:
        proc = subprocess.Popen(['anvil', '--fork-url', url, '--fork-block-number', str(block),
            '--fork-header', f'User-Agent: {UA}', '--accounts', '0', '--host', '127.0.0.1',
            '--port', str(port), '--silent'], stdout=log, stderr=subprocess.STDOUT)
        try:
            ready = False
            for _ in range(100):
                if proc.poll() is not None:
                    break
                try:
                    ready = int(rpc(local, 'eth_chainId', []), 16) == chain
                    if ready:
                        break
                except Exception:
                    time.sleep(0.2)
            if not ready:
                raise SystemExit('fork startup failed; retained anvil.log (check archive-state availability)')
            env = {**os.environ, 'FOUNDRY_TEST': 'verification/fork'}
            with (args.out / 'forge.log').open('w') as result:
                command = ['forge', 'test', '--fork-url', local, '-vvvvv' if args.trace else '-vvv']
                if args.match_test: command += ['--match-test', args.match_test]
                manifest['forgeCommand'] = command
                run = subprocess.run(command, env=env,
                    cwd=Path(__file__).resolve().parents[1], stdout=result, stderr=subprocess.STDOUT)
            manifest['forgeExitCode'] = run.returncode
            (args.out / 'fork.json').write_text(json.dumps(manifest, indent=2) + '\n')
            output = (args.out / 'forge.log').read_text()
            if args.trace:
                measurements = {}
                # Each matched test has its own Logs/Traces pair. Keep measurements
                # from later tests too; trace tree lines do not match this pattern.
                for line in output.splitlines():
                    match = re.match(r'^  ([A-Za-z][^:\r\n]*): (0x[0-9a-fA-F]+|[0-9]+)$', line)
                    if match:
                        key, value = match.groups()
                        if key in measurements:
                            previous = measurements[key]
                            measurements[key] = previous + [value] if isinstance(previous, list) else [previous, value]
                        else:
                            measurements[key] = value
                (args.out / 'summary.json').write_text(json.dumps({
                    'status': 'PASS' if run.returncode == 0 else 'FAIL',
                    'fork': manifest, 'measurements': measurements,
                    'assumptions': manifest['limits'] + ' Gas is local warmed execution, not live transaction fees. Constructor values/addresses are LOCAL ONLY.'
                }, indent=2) + '\n')
            print(output)
            raise SystemExit(run.returncode)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()

if __name__ == '__main__':
    main()
