#!/usr/bin/env python3
"""Exit 0 when Valetudo state attributes on stdin say docked with an idle dock.

Exit 1 otherwise and 2 when stdin is not state-attribute JSON. Valetudo places
"metaData" between "__class" and "value", so the JSON is parsed, not grepped.
"""
import json
import sys

try:
    attributes = {a.get("__class"): a for a in json.load(sys.stdin)}
except (ValueError, TypeError, AttributeError):
    sys.exit(2)

status = attributes.get("StatusStateAttribute", {}).get("value")
dock = attributes.get("DockStatusStateAttribute", {}).get("value")
sys.exit(0 if status == "docked" and dock == "idle" else 1)
