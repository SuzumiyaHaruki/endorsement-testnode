#!/usr/bin/env python3
import json
import sys
from pathlib import Path

base_path = Path(sys.argv[1])
override_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])

base = json.loads(base_path.read_text(encoding="utf-8"))
override = json.loads(override_path.read_text(encoding="utf-8"))

def deep_merge(dst, src):
    if isinstance(dst, dict) and isinstance(src, dict):
        out = dict(dst)
        for k, v in src.items():
            if k in out:
                out[k] = deep_merge(out[k], v)
            else:
                out[k] = v
        return out
    return src

merged = deep_merge(base, override)
out_path.write_text(json.dumps(merged, ensure_ascii=False, indent=2), encoding="utf-8")
print(out_path)