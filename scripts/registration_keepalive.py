#!/usr/bin/env python3
"""OPTIONS-only keepalive for fresh PBX-authenticated numeric-extension slots.
No registration writes, no PBX credentials, no socket listener, no restarts.
Kamailio sends OPTIONS over its existing public socket through local Unix RPC.
"""
from __future__ import annotations
import argparse
import hashlib
import ipaddress
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

LOG = logging.getLogger('coovox.registration_keepalive')
ENTRY = re.compile(r'name:\s*([^\r\n]+)\r?\n\s*value:\s*([^\r\n]+)\r?\n\s*type:\s*(str|int)')
PEER = re.compile(r'^sip:([0-9.]+):([0-9]{1,5})$')


def parse_table(text: str) -> dict[str, str | int]:
    """Parse only typed htable entries; fail closed on malformed/duplicate keys."""
    if 'error:' in text.lower():
        raise ValueError('RPC htable error')
    data: dict[str, str | int] = {}
    for name, value, kind in ENTRY.findall(text):
        name, value = name.strip(), value.strip()
        if name in data:
            raise ValueError('Duplicate htable key')
        data[name] = int(value) if kind == 'int' else value
    if 'name:' in text and not data:
        raise ValueError('Unrecognized htable format')
    return data


def select_peers(table: dict[str, str | int], extensions: list[str],
                 now: float, max_age: int, max_targets: int) -> list[dict]:
    targets, used = [], set()
    for ext in extensions:
        if not re.fullmatch(r'1[0-9]{2}', ext):
            raise ValueError('Only explicitly allowed numeric extensions 100-199')
        for slot in range(1, 6):
            key = f'{ext}#{slot}'
            uri, seen = table.get(key), table.get(key + '#ts')
            if not isinstance(uri, str) or not isinstance(seen, int):
                continue
            if not (0 <= now - seen <= max_age):
                continue
            match = PEER.fullmatch(uri)
            if not match:
                continue
            address = ipaddress.IPv4Address(match[1])
            port = int(match[2])
            # The feature is for Internet endpoints; never probe local services.
            if not address.is_global or address.is_multicast or not 1024 <= port <= 65535:
                continue
            peer = (str(address), port)
            if peer in used:
                continue
            used.add(peer)
            targets.append({'extension': ext, 'slot': slot,
                            'ruri': f'sip:{ext}@{address}:{port}',
                            'peer_id': hashlib.sha256(uri.encode()).hexdigest()[:12],
                            'registration_timestamp': seen})
            if len(targets) >= max_targets:
                return targets
    return targets


def load_config(path: Path) -> dict:
    cfg = json.loads(path.read_text(encoding='utf-8'))
    extensions = cfg.get('extensions')
    if not isinstance(extensions, list) or not extensions or len(extensions) > 5:
        raise ValueError('An explicit extension allowlist (1-5 entries) is required')
    if any(not isinstance(x, str) or not re.fullmatch(r'1[0-9]{2}', x) for x in extensions):
        raise ValueError('Invalid numeric extension')
    domain = cfg.get('sip_domain', '')
    if not re.fullmatch(r'[A-Za-z0-9.-]{1,253}', domain):
        raise ValueError('Invalid SIP domain')
    match = re.fullmatch(r'udp:([0-9.]+):([0-9]{1,5})', cfg.get('send_socket', ''))
    if not match or not ipaddress.IPv4Address(match[1]).is_global or not 1024 <= int(match[2]) <= 65535:
        raise ValueError('Invalid public UDP send socket')
    if cfg.get('rpc_socket') != 'unix:/var/lib/coovox-sip/kamailio_ctl':
        raise ValueError('Only the existing local Kamailio RPC socket is permitted')
    cfg.setdefault('max_registration_age_seconds', 900)
    cfg.setdefault('max_targets', 5)
    if not 60 <= cfg['max_registration_age_seconds'] <= 3600:
        raise ValueError('Registration freshness bound outside 60..3600 seconds')
    if not 1 <= cfg['max_targets'] <= 5:
        raise ValueError('Target cap must be 1..5')
    return cfg


def rpc(socket_name: str, method: str, args: list[str], timeout: float = 2) -> str:
    # kamcmd treats an unprefixed empty string as integer 0: s: is essential.
    cmd = ['/usr/sbin/kamcmd', '-s', socket_name, method] + ['s:' + a for a in args]
    result = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout, check=False)
    if result.returncode != 0 or re.search(r'(^|\n)\s*error:', result.stdout, re.I):
        raise RuntimeError(f'Kamailio RPC {method} failed')
    return result.stdout


def make_headers(ext: str, domain: str) -> str:
    return (f'From: <sip:keepalive@{domain}>\r\n'
            f'To: <sip:{ext}@{domain}>\r\n'
            f'Call-ID: coovoxka-{uuid.uuid4().hex}@{domain}\r\n'
            'User-Agent: CooVox-Registration-Keepalive/1.0\r\n')


def write_status(path: Path, report: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    os.replace(temp, path)


def run_once(cfg: dict, status: Path | None, dry_run: bool = False) -> dict:
    now = time.time()
    table = parse_table(rpc(cfg['rpc_socket'], 'htable.dump', ['regmulti']))
    targets = select_peers(table, cfg['extensions'], now,
                           cfg['max_registration_age_seconds'], cfg['max_targets'])
    queued, failures = [], 0
    for target in targets:
        if not dry_run:
            try:
                rpc(cfg['rpc_socket'], 'tm.t_uac_start',
                    ['OPTIONS', target['ruri'], '.', cfg['send_socket'],
                     make_headers(target['extension'], cfg['sip_domain']), ''])
            except (OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
                failures += 1
                LOG.warning('OPTIONS enqueue failed ext=%s slot=%s kind=%s',
                            target['extension'], target['slot'], type(exc).__name__)
                continue
        queued.append({k: v for k, v in target.items() if k != 'ruri'})
    report = {'timestamp': int(now), 'dry_run': dry_run,
              'allowed_extensions': cfg['extensions'], 'eligible_count': len(targets),
              'options_queued': len(queued), 'rpc_failures': failures, 'peers': queued,
              'note': 'Queued requests are NOT proof of response or successful registration.'}
    if status and not dry_run:
        write_status(status, report)
    LOG.info('allowed=%s fresh_peers=%d OPTIONS_queued=%d RPC_errors=%d dry_run=%s',
             ','.join(cfg['extensions']), len(targets), len(queued), failures, dry_run)
    return report


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--config', type=Path, default=Path('/etc/kamailio/registration-keepalive.json'))
    ap.add_argument('--status', type=Path, default=Path('/var/lib/coovox-nat-keepalive/status.json'))
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    cfg = load_config(args.config)
    report = run_once(cfg, args.status, args.dry_run)
    if args.dry_run:
        print(json.dumps(report, indent=2))
    return 1 if report['rpc_failures'] else 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        LOG.error('Keepalive stopped safely: %s', exc)
        raise SystemExit(1) from exc
