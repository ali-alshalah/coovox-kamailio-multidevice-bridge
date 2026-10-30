#!/usr/bin/env python3
"""Render sanitized, versioned production templates without third-party packages."""
import argparse
import hashlib
import ipaddress
import json
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ("SIP_PUBLIC_IP", "SIP_PUBLIC_HOST", "VPN_SERVER_IP", "PBX_VPN_IP")
TEMPLATES = {
    "templates/kamailio/coovox.cfg.tpl": "coovox.cfg",
    "templates/rtpengine/coovox.conf.tpl": "rtpengine.conf",
    "templates/network/coovox-sip-official-proxy.tpl": "coovox-sip-official-proxy",
    "templates/network/coovox-sip-forward-LEGACY.tpl": "coovox-sip-forward-LEGACY",
    "templates/network/coovox-rtp-forward-LEGACY.tpl": "coovox-rtp-forward-LEGACY",
}


def read_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            raise ValueError(f"Line {index}: expected KEY=VALUE")
        name, value = stripped.split("=", 1)
        name = name.strip()
        value = value.strip().strip('"').strip("'")
        if name not in REQUIRED:
            raise ValueError(f"Line {index}: unsupported variable {name!r}")
        if name in data or not value:
            raise ValueError(f"Line {index}: duplicate or empty {name}")
        data[name] = value
    missing = set(REQUIRED) - set(data)
    if missing:
        raise ValueError(f"Missing variables: {', '.join(sorted(missing))}")
    for name in ("SIP_PUBLIC_IP", "VPN_SERVER_IP", "PBX_VPN_IP"):
        ipaddress.IPv4Address(data[name])
    host = data["SIP_PUBLIC_HOST"]
    if not re.fullmatch(r"(?=.{4,253}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", host):
        raise ValueError("SIP_PUBLIC_HOST must be a DNS host name")
    if data["SIP_PUBLIC_IP"] == data["VPN_SERVER_IP"]:
        raise ValueError("Public and VPN server IPs must be distinct")
    if data["VPN_SERVER_IP"] == data["PBX_VPN_IP"]:
        raise ValueError("VPN server and PBX IPs must be distinct")
    return data


def render(source: str, variables: dict[str, str]) -> str:
    text = source
    for key, value in variables.items():
        text = text.replace("{{" + key + "}}", value)
    if re.search(r"{{[A-Z_]+}}", text):
        raise ValueError("Unresolved template variable")
    return text


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--env", type=Path, required=True, help="Local KEY=VALUE file; never commit it")
    ap.add_argument("--output", type=Path, default=ROOT / "build", help="Output directory")
    args = ap.parse_args()
    variables = read_env(args.env)
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    artifacts = {}
    for src, dest in TEMPLATES.items():
        content = render((ROOT / src).read_text(encoding="utf-8"), variables)
        target = output / dest
        target.write_text(content, encoding="utf-8")
        target.chmod(0o750 if "forward" in dest or "proxy" in dest else 0o640)
        artifacts[dest] = hashlib.sha256(content.encode("utf-8")).hexdigest()
    manifest = {"version": "v1.0.0", "files": artifacts}
    (output / "SHA256.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256.json").chmod(0o600)
    print("Rendered:", ", ".join(artifacts))
    print("Validate Kamailio with: kamailio -c -f", output / "coovox.cfg")
    print("Never publish build/ or your real .env")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        raise SystemExit(f"ERROR: {exc}") from exc
