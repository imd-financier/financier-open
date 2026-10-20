#!/usr/bin/env python3
"""Offline verification of the public snapshot's reviewed build templates and ABIs."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
pins = json.loads((root / 'BUILD_PINS.json').read_text())
manifest = json.loads((root / 'SOURCE_MANIFEST.json').read_text())
for path, expected in manifest['files'].items():
    data = (root / path).read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], path
    assert len(data) == expected['bytes'], path
for item in pins['contracts'] + [dict(name='PublisherGateway',
        creationKeccak=pins['gateway']['creationKeccak'], creationBytes=pins['gateway']['creationBytes'],
        runtimeTemplateKeccak=pins['gateway']['runtimeKeccak'], runtimeTemplateBytes=pins['gateway']['runtimeBytes'])]:
    artifact = json.loads((root / 'out' / (item['name'] + '.sol') / (item['name'] + '.json')).read_text())
    for field, size, digest in [('bytecode', 'creationBytes', 'creationKeccak'),
                                ('deployedBytecode', 'runtimeTemplateBytes', 'runtimeTemplateKeccak')]:
        code = artifact[field]['object']
        assert len(bytes.fromhex(code.removeprefix('0x'))) == item[size], item['name']
        actual = subprocess.check_output(['cast', 'keccak', code], text=True).strip()
        assert actual == item[digest], item['name']
for path, digest in pins['abi'].items():
    raw = (root / path).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == digest, path
    name = Path(path).stem
    artifact = json.loads((root / 'out' / (name + '.sol') / (name + '.json')).read_text())
    assert json.loads(raw) == artifact['abi'], path
print(json.dumps(dict(status='PASS', reviewedBuilds=10, reviewedAbis=len(pins['abi']),
                      manifestPayloads=len(manifest['files']), productionRuntimeVerified=False)))
