#!/usr/bin/env python3
"""Read-only, chain-pinned evidence collector. Never signs or sends a transaction.
Requires cast on PATH for Ethereum Keccak/selectors (stdlib hashlib SHA3 is NOT Keccak).
Run: python script/readiness_rpc.py --out /tmp/financier-chain-evidence
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import urllib.request

UA = 'FINANCIER-read-only-readiness/1.0'
NETWORKS = {
    'robinhood': ('https://rpc.mainnet.chain.robinhood.com', 4663, {
        'factory': '0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e',
        'registry': '0xf52bbe066b7ad2d28c2195d066ea08dcbca88406',
        'imd': '0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127',
        'intake': '0xa43e6f75ee006411f79ac1c84120606c2330de82'}),
    'ethereum': ('https://ethereum-rpc.publicnode.com', 1, {
        'workRegistry': '0xb6d0a187b050fa5bb0b87033a203f37becf4a775'}),
    'robinhood-testnet': ('https://rpc.testnet.chain.robinhood.com', 46630, {}),
    'sepolia': ('https://ethereum-sepolia-rpc.publicnode.com', 11155111, {
        'factory': '0x84cf2bc1dc2af577dba5d62e26f90d041ca38f7a',
        'registry': '0x90aaedd35073e2a31861276e58081251a601aad9'})}
READ_METHODS = frozenset({'eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber', 'eth_getCode',
    'eth_getStorageAt', 'eth_call', 'eth_getTransactionByHash', 'eth_getTransactionReceipt', 'eth_gasPrice'})
SLOTS = ['0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',
    '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103',
    '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50']
GETTERS = ['registry()', 'deployer()', 'writer()', 'signer()', 'owner()', 'admin()',
           'decimals()', 'symbol()', 'payTo()', 'poolManager()']
TXS = {'robinhood': '0xdcb2e5a445cd6b0b311f2566c84f6f18062964622c0a299015935ee6772bf1b5',
       'ethereum': '0x952500a5c41cae67745dd5ea162855c6060900e529268e88c3cebee07bef1c21'}


def cast(*args):
    return subprocess.check_output(['cast', *args], text=True).strip()


def rpc(url, method, params):
    if method not in READ_METHODS:
        raise ValueError('only read-only RPC methods permitted')
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
    req = urllib.request.Request(url, data=body, headers={'Content-Type': 'application/json', 'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=20) as response:
        result = json.load(response)
    if 'error' in result:
        raise RuntimeError(result['error'])
    return result['result']


def optional(fn):
    try:
        return fn()
    except Exception as exc:
        return {'error': str(exc)}


def collect(name):
    url, chain, addresses = NETWORKS[name]
    data = {'url': url, 'retrievedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'expectedChainId': chain}
    try:
        actual = int(rpc(url, 'eth_chainId', []), 16)
        if actual != chain:
            raise ValueError(f'wrong chain: {actual}')
        block = rpc(url, 'eth_getBlockByNumber', ['latest', False]); pin = block['number']
        data.update(chainId=actual, block=block, contracts={})
        for label, address in addresses.items():
            code = rpc(url, 'eth_getCode', [address, pin])
            data['contracts'][label] = {'address': address, 'code': code, 'codeHash': cast('keccak', code),
                'storage': {slot: optional(lambda: rpc(url, 'eth_getStorageAt', [address, slot, pin])) for slot in SLOTS},
                'calls': {sig: optional(lambda: rpc(url, 'eth_call', [{'to': address, 'data': cast('sig', sig)}, pin])) for sig in GETTERS}}
        if name in TXS:
            data['transaction'] = rpc(url, 'eth_getTransactionByHash', [TXS[name]])
            data['receipt'] = rpc(url, 'eth_getTransactionReceipt', [TXS[name]])
            data['receiptBlock'] = rpc(url, 'eth_getBlockByNumber', [data['receipt']['blockNumber'], False])
            if data['receipt']['blockHash'] != data['receiptBlock']['hash']:
                raise ValueError('receipt is not in canonical block')
        if name == 'ethereum':
            data['finalized'] = rpc(url, 'eth_getBlockByNumber', ['finalized', False])
            address = addresses['workRegistry']
            data['historicalWriter'] = optional(lambda: rpc(url, 'eth_call', [{'to': address, 'data': cast('sig', 'writer()')}, data['receipt']['blockNumber']]))
        if name == 'robinhood':
            data['cancunMcopyCall'] = rpc(url, 'eth_call', [{'data': '0x60016000526020600060205e60206020f3'}, pin])
        data['endBlockHash'] = rpc(url, 'eth_getBlockByNumber', [pin, False])['hash']
        if data['endBlockHash'] != block['hash']:
            raise ValueError('pinned block changed during retrieval')
    except Exception as exc:
        data['error'] = str(exc)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--network', choices=list(NETWORKS), action='append')
    args = parser.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    failed = False
    for name in args.network or NETWORKS:
        data = collect(name); (args.out / f'{name}.json').write_text(json.dumps(data, indent=2) + '\n')
        print(name, data.get('error', f"pinned {data.get('block', {}).get('number')}"), flush=True)
        failed |= 'error' in data
    raise SystemExit(1 if failed else 0)

if __name__ == '__main__':
    main()
