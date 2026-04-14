#!/usr/bin/env python3
import json
import sys
from pathlib import Path

case_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

case = json.loads(case_path.read_text(encoding="utf-8"))

cfg = {
    "execution": {
        "sequencer": {
            "experimental-batching-window": f'{case["batching_window_ms"]}ms'
        },
        "endorsement-experiment": {
            "enable": case["mode"] != "disabled",
            "mode": case["mode"],
            "default-threshold": case["default_threshold"],
            "strict-threshold": case["strict_threshold"],
            "default-aggregation": case["default_aggregation"],
            "strict-aggregation": case["strict_aggregation"],
            "block-endorsement-timeout": f'{case["block_endorsement_timeout_ms"]}ms',
            "max-rebuild-rounds": case["max_rebuild_rounds"],
            "fail-to-address": "0x1111111111111111111111111111111111111111",

            "endorser-a-url": "http://endorser-a:9001",
            "endorser-b-url": "http://endorser-b:9002",
            "endorser-c-url": "http://endorser-c:9003",

            "endorser-a-pubkey": "a3f44d234234430c7c7c3268d5f49a674edc2281bb0aec9ea14be8b598c22c7ad0d909d14b35a4c5d64e155dd28d81ba",
            "endorser-b-pubkey": "ad10f131ec7851674af913cbc0a62ebb7efd981535e3a0fdcdadc8c7e33bd7e494d4488b018d55659a7d44346b31ebc1",
            "endorser-c-pubkey": "90f21d7ed995c790d21df79dcc2ad4e1464520108b46767c9326b56c6cce09bb9356962c06471ac1185ea9bc9df43a9b"
        }
    }
}

out_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
print(out_path)