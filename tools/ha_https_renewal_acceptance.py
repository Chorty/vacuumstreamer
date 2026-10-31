#!/usr/bin/env python3
"""Record a real renewed leaf only after HA verifies the exact served leaf."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import ssl
import sys
import tempfile

CERT = Path("/ssl/valetudo-fullchain.pem")
STATE = Path("/config/valetudo_https_renewal_acceptance_state.json")
SYNC = Path("/config/valetudo_https_cert_sync.py")


def fingerprint(certificate):
    with certificate.open("rb") as source:
        pem = source.read(98305)
    if len(pem) > 98304:
        raise ValueError("certificate too large")
    match = re.search(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    if not match:
        raise ValueError("missing leaf")
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(match[0].decode("ascii"))).digest()


def verify_served(expected):
    spec = importlib.util.spec_from_file_location("valetudo_cert_sync", SYNC)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    helper.verify_served(expected)


def write_state(path, state, initialize):
    contents = json.dumps(state, indent=2) + "\n"
    if initialize:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write(contents)
        return
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(contents)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def check(certificate=CERT, state_file=STATE, initialize=False):
    leaf = fingerprint(certificate)
    # Existing verifier checks trust, hostname, >=14 days remaining, exact
    # served leaf and an HTTP 200/401 response before any state is advanced.
    verify_served(leaf)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    current = leaf.hex()
    if initialize:
        state = {"baseline": current, "last_verified": current, "initialized_at": now}
        write_state(state_file, state, True)
        newly_verified = False
    else:
        with state_file.open() as source:
            contents = source.read(16385)
        if len(contents) > 16384:
            raise ValueError("state too large")
        state = json.loads(contents)
        for key in ("baseline", "last_verified"):
            if not re.fullmatch(r"[0-9a-f]{64}", state[key]):
                raise ValueError("invalid state")
        newly_verified = current != state["baseline"] and current != state["last_verified"]
        if newly_verified:
            state.update(last_verified=current, verified_at=now)
            write_state(state_file, state, False)
    return {"renewed": current != state["baseline"], "newly_verified": newly_verified,
            "fingerprint": current, "checked_at": now}


def main():
    if sys.argv[1:] not in ([], ["init"]):
        return 2
    try:
        print(json.dumps(check(initialize=sys.argv[1:] == ["init"])))
    except Exception:
        print("Valetudo renewal acceptance check failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
