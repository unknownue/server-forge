#!/bin/bash
# Patch the MTP quantization_config in the Qwen3.8-27B W4A16 GPTQ checkpoint.
#
# Why: the upstream checkpoint stores all 15 MTP tensors as plain BF16 in
# `model_extra_tensors.safetensors`, but its `quantization_config.dynamic`
# declares POSITIVE rules ("+:.*mtp.*", "+:.*mtp\.fc.*") claiming they are
# 4-bit. The GPTQ weight loader (SGLang and vLLM alike) trusts that config,
# tries to dequantize MTP layers that were never quantized, and fails at load.
#
# Fix: replace those positive rules with a single NEGATIVE exclusion rule so the
# loader skips quantization for MTP and reads the BF16 weights as-is.
# Source: https://github.com/StevenChenSE/sglang/tree/gfx1100-support#chinese
#
# Usage:
#   bash nodes/ubuntu-server-node-2/serve/patch-mtp-quant-config.sh [MODEL_DIR]
#
# Idempotent: re-running on an already-patched checkpoint reports and exits 0.

set -euo pipefail

MODEL_DIR="${1:-/data/work/models/Vishva007/Qwen3.8-27B-W4A16-AutoRound-GPTQ}"
CONFIG="$MODEL_DIR/config.json"

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: config.json not found: $CONFIG" >&2
    echo "Download the model first:" >&2
    echo "  bash nodes/ubuntu-server-node-2/download-model.sh" >&2
    exit 1
fi

log "Patching: $CONFIG"

python3 - "$CONFIG" <<'PYEOF'
import json, shutil, sys, datetime

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

qc = cfg.get("quantization_config")
if qc is None:
    print("No quantization_config present — nothing to do.")
    sys.exit(0)

dyn = qc.get("dynamic")
if dyn is None:
    print("No quantization_config.dynamic present — nothing to do.")
    sys.exit(0)

print("Before:", json.dumps(dyn, indent=2))

# The buggy rules are the ones that *include* mtp tensors in quantization.
bad = [k for k in dyn if "mtp" in k and k.startswith("+")]
if not bad:
    if any("mtp" in k and k.startswith("-") for k in dyn):
        print("\nAlready patched (negative MTP exclusion rule present) — no change.")
        sys.exit(0)
    print("\nNo positive MTP rules found — no change needed.")
    sys.exit(0)

for k in bad:
    del dyn[k]

# Single negative rule covering every MTP tensor, read as BF16.
dyn["-:.*mtp.*"] = {"bits": 16, "group_size": 128}

cfg["quantization_config"]["dynamic"] = dyn

backup = path + ".bak." + datetime.datetime.now().strftime("%Y%m%d%H%M%S")
shutil.copy2(path, backup)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("\nAfter:", json.dumps(dyn, indent=2))
print(f"\nBackup written: {backup}")
print(f"Patched rules removed: {bad}")
PYEOF

log "Done. SGLang should now load the MTP layers as BF16."