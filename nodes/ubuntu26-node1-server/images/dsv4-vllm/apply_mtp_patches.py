#!/usr/bin/env python3
"""Apply Acti's three MTP-loader patches to vllm/model_executor/models/deepseek_v4_mtp.py.

Patch 4a — pass `prefix=` to e_proj and h_proj constructors
Patch 4b — `packed_modules_mapping` class attribute on DeepSeekV4MTP
Patch 4c — `.weight_scale` (not `.weight_scale_inv`) in the MTP loader suffix branch
"""
from __future__ import annotations
import re
import sys

if len(sys.argv) != 2:
    print("usage: apply_mtp_patches.py <path/to/deepseek_v4_mtp.py>", file=sys.stderr)
    sys.exit(2)
path = sys.argv[1]
with open(path) as f:
    src = f.read()


# ----- Patch 4a: prefix= for e_proj / h_proj -----
def patch_4a(s: str) -> str:
    pattern = re.compile(
        r"(self\.(e_proj|h_proj)\s*=\s*ReplicatedLinear\(\s*"
        r"config\.hidden_size,\s*config\.hidden_size,\s*"
        r"bias=False,\s*return_bias=False,\s*"
        r"quant_config=quant_config,)\s*\)",
        re.MULTILINE,
    )

    def repl(m: re.Match) -> str:
        attr = m.group(2)  # 'e_proj' or 'h_proj'
        return f'{m.group(1)}\n            prefix=f"{{prefix}}.{attr}",\n        )'

    new = pattern.sub(repl, s)
    if new == s:
        raise SystemExit(
            "Patch 4a anchor not found. The constructor signature for e_proj/h_proj has changed."
        )
    return new


# ----- Patch 4b: packed_modules_mapping class attribute on DeepSeekV4MTP -----
def patch_4b(s: str) -> str:
    needle = "class DeepSeekV4MTP(nn.Module):\n"
    if needle not in s:
        raise SystemExit("Patch 4b anchor 'class DeepSeekV4MTP(nn.Module):' not found.")
    if "packed_modules_mapping" in s.split(needle, 1)[1].split("def __init__", 1)[0]:
        # Already patched.
        return s
    insert = (
        '    # PATCH (DSV4-MTP-splice): mirror DeepseekV4ForCausalLM.packed_modules_mapping\n'
        '    packed_modules_mapping = {\n'
        '        "fused_wqa_wkv": ["wq_a", "wkv"],\n'
        '        "fused_wkv_wgate": ["wkv", "wgate"],\n'
        '        "gate_up_proj": ["w1", "w3"],\n'
        '    }\n\n'
    )
    return s.replace(needle, needle + insert, 1)


# ----- Patch 4c: ".weight_scale" (no _inv) in MTP loader -----
def patch_4c(s: str) -> str:
    # The else-branch in DeepSeekV4MTP.load_weights' suffix selection.
    # The original line is:
    #     else ".weight_scale_inv"
    # The patched line is:
    #     else ".weight_scale"
    # We rewrite only inside the suffix-pick block to avoid touching unrelated
    # uses of weight_scale_inv elsewhere in the file.
    pattern = re.compile(
        r"(suffix\s*=\s*\(\s*expert_scale_suffix\s*if\s+_EXPERT_SCALE_RE\.search\(name\)\s*"
        r"(?:#.*\n\s*)*else\s+)\"\.weight_scale_inv\"",
        re.MULTILINE,
    )
    new, n = pattern.subn(r'\1".weight_scale"', s)
    if n == 0:
        # Already patched? Check.
        if 'else ".weight_scale"' in s and 'else ".weight_scale_inv"' not in s:
            return s
        raise SystemExit(
            "Patch 4c anchor not found. The suffix-pick logic in DeepSeekV4MTP.load_weights has changed."
        )
    return new


new = patch_4c(patch_4b(patch_4a(src)))

with open(path, "w") as f:
    f.write(new)
print(f"Applied patches 4a, 4b, 4c to {path}")
