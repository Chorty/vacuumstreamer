#!/usr/bin/env python3
"""Install/acknowledge a robot certificate, or independently check served expiry.

No credentials, keys, certificate contents, or subprocess diagnostics are logged.
The SSH forced command rolls back if this process exits without acknowledging.
"""
import fcntl
import hashlib
import re
import select
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path

HOST = "mattjoslin-valetudo.duckdns.org"
CERT = Path("/ssl/valetudo-fullchain.pem")
KEY = Path("/ssl/valetudo-privkey.pem")
SSH = ["ssh", "-i", "/config/.ssh/valetudo_https_ed25519", "-o", "BatchMode=yes",
       "-o", "ConnectTimeout=8", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
       "-o", "UserKnownHostsFile=/config/.ssh/known_hosts", "-o", "ServerAliveInterval=5",
       "-o", "ServerAliveCountMax=2", "root@192.168.1.31", "install"]


def verify_served(expected=None):
    context = ssl.create_default_context()
    with socket.create_connection((HOST, 443), timeout=4) as raw:
        with context.wrap_socket(raw, server_hostname=HOST) as connection:
            leaf = connection.getpeercert(binary_form=True)
            if expected is not None and hashlib.sha256(leaf).digest() != expected:
                raise ValueError("unexpected served certificate")
            if ssl.cert_time_to_seconds(connection.getpeercert()["notAfter"]) - time.time() < 14 * 86400:
                raise ValueError("served certificate approaches expiry")
            connection.sendall(("GET /api/v2/robot HTTP/1.1\r\nHost: " + HOST + "\r\nConnection: close\r\n\r\n").encode("ascii"))
            response = bytearray()
            deadline = time.monotonic() + 4
            while b"\r\n" not in response and len(response) < 1024:
                connection.settimeout(max(0.01, deadline - time.monotonic()))
                chunk = connection.recv(1)
                if not chunk or time.monotonic() > deadline:
                    raise ValueError("incomplete HTTP response")
                response.extend(chunk)
            if not re.match(rb"HTTP/1\.[01] (200|401) ", response):
                raise ValueError("HTTPS API unhealthy")


def install():
    # Read bounded snapshots; renewal between these reads fails pair validation.
    with CERT.open("rb") as source:
        certificate = source.read(98305)
    with KEY.open("rb") as source:
        key = source.read(98305)
    bundle = certificate + b"\n" + key
    if len(bundle) > 98304:
        raise ValueError("certificate bundle too large")
    match = re.search(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificate, re.S)
    if not match:
        raise ValueError("missing leaf certificate")
    expected = hashlib.sha256(ssl.PEM_cert_to_DER_cert(match[0].decode("ascii"))).digest()
    process = subprocess.Popen(SSH, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        process.stdin.write(f"{len(bundle):06d}\n".encode("ascii") + bundle)
        process.stdin.flush()
        if not select.select([process.stdout], [], [], 40)[0] or process.stdout.readline(16) != b"ready\n":
            raise ValueError("installer did not become ready")
        verify_served(expected)
        process.stdin.write(b"commit\n")
        process.stdin.close()
        if process.wait(timeout=5) != 0:
            raise ValueError("installer did not commit")
    finally:
        if not process.stdin.closed:
            process.stdin.close()  # EOF triggers remote rollback.
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=2)
        process.stdout.close()


def main():
    try:
        if sys.argv[1:] == ["check"]:
            verify_served()
        elif not sys.argv[1:]:
            with open("/config/.ssh/valetudo_https_sync.lock", "a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                install()
        else:
            raise ValueError("invalid command")
    except Exception:
        print("Valetudo HTTPS certificate check/install failed", file=sys.stderr)
        return 1
    print("Valetudo HTTPS certificate verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
