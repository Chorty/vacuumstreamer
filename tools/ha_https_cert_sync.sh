#!/bin/sh
# HA shell_command wrapper. Deploy the Python helper alongside this file.
exec python3 /config/valetudo_https_cert_sync.py "$@"
