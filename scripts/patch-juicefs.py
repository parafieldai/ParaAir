#!/usr/bin/env python3
"""Checked, idempotent compatibility patch for the pinned JuiceFS revision."""
import pathlib
import sys

source = pathlib.Path(sys.argv[1]) / "pkg/object/s3.go"
original = '\tif region == "" {\n\t\tregion = os.Getenv("AWS_REGION")\n\t}'
replacement = '''\t// StreamDrive: each connection supplies its own signing region.
\tif configured := uri.Query().Get("streamdrive-region"); configured != "" {
\t\tregion = configured
\t}
''' + original
data = source.read_text()
if replacement not in data:
    if data.count(original) != 1:
        raise SystemExit("Pinned JuiceFS S3 region patch no longer matches; review upstream source")
    source.write_text(data.replace(original, replacement))
