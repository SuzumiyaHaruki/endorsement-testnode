#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

case_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

case = json.loads(case_path.read_text(encoding="utf-8"))

endorser_a_url = os.environ.get("ENDORSER_A_URL", "http://endorser-a:9001")
endorser_b_url = os.environ.get("ENDORSER_B_URL", "http://endorser-b:9002")
endorser_c_url = os.environ.get("ENDORSER_C_URL", "http://endorser-c:9003")

endorser_a_pubkey = os.environ.get(
    "ENDORSER_A_PUBKEY",
    "a3f44d234234430c7c7c3268d5f49a674edc2281bb0aec9ea14be8b598c22c7ad0d909d14b35a4c5d64e155dd28d81ba",
)
endorser_b_pubkey = os.environ.get(
    "ENDORSER_B_PUBKEY",
    "ad10f131ec7851674af913cbc0a62ebb7efd981535e3a0fdcdadc8c7e33bd7e494d4488b018d55659a7d44346b31ebc1",
)
endorser_c_pubkey = os.environ.get(
    "ENDORSER_C_PUBKEY",
    "90f21d7ed995c790d21df79dcc2ad4e1464520108b46767c9326b56c6cce09bb9356962c06471ac1185ea9bc9df43a9b",
)

fail_to_address = os.environ.get("FAIL_TO_ADDRESS", "0x1111111111111111111111111111111111111111")

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
            "fail-to-address": fail_to_address,

            "endorser-a-url": endorser_a_url,
            "endorser-b-url": endorser_b_url,
            "endorser-c-url": endorser_c_url,

            "endorser-a-pubkey": endorser_a_pubkey,
            "endorser-b-pubkey": endorser_b_pubkey,
            "endorser-c-pubkey": endorser_c_pubkey,
        }
    }
}

out_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
print(out_path)
