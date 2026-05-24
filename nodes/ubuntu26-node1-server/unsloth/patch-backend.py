#!/usr/bin/env python3
"""Patch Unsloth Studio backend (runs after frontend build).

1. inference.py (core): auto-detect native quantization_config (FP8, NVFP4,
   etc.) and skip BitsAndBytesConfig to avoid conflicts.
2. inference.py (routes): detect enable_thinking in chat template and enable
   reasoning support for Qwen3 models.
3. main.py: always inject bootstrap credentials so the frontend can
   auto-login (not just when password change is pending).
4. storage.py: set must_change_password=False so first-time login skips
   the forced change-password flow.
"""

STUDIO_DIR = "/opt/venv/lib/python3.12/site-packages/studio"
INFERENCE = f"{STUDIO_DIR}/backend/core/inference/inference.py"
INFERENCE_ROUTES = f"{STUDIO_DIR}/backend/routes/inference.py"
MAIN = f"{STUDIO_DIR}/backend/main.py"
STORAGE = f"{STUDIO_DIR}/backend/auth/storage.py"


# ── Patch inference.py: skip BitsAndBytesConfig for pre-quantized models ──

with open(INFERENCE) as f:
    content = f.read()

# Insert after "model_name = config.identifier", before "# Check if already loaded"
marker = (
    "            model_name = config.identifier\n"
    "\n"
    "            # Check if already loaded"
)
if marker not in content:
    raise SystemExit(f"ERROR: inference.py marker not found in {INFERENCE}")

patch = (
    "            model_name = config.identifier\n"
    "\n"
    "            # Auto-detect native quantization_config (FP8, CompressedTensors /\n"
    "            # NVFP4, MXFP4, etc.) in the model's config.json. When a native\n"
    "            # quantization scheme is present, disable 4-bit loading to avoid\n"
    "            # creating a conflicting BitsAndBytesConfig.\n"
    "            model_cfg_path = Path(config.path) / \"config.json\"\n"
    "            try:\n"
    "                if model_cfg_path.exists():\n"
    "                    model_cfg = json.loads(model_cfg_path.read_text())\n"
    "                    if model_cfg.get(\"quantization_config\"):\n"
    "                        qc = model_cfg[\"quantization_config\"]\n"
    "                        qc_type = (\n"
    "                            \"CompressedTensors\" if \"config_groups\" in qc\n"
    "                            else qc.get(\"quant_method\", \"unknown\")\n"
    "                        )\n"
    "                        logger.info(\n"
    "                            f\"Native quantization_config detected in {model_name} \"\n"
    "                            f\"({qc_type}), disabling 4-bit loading\"\n"
    "                        )\n"
    "                        # Native quantization (FP8, NVFP4, etc.) conflicts\n"
    "                        # with BitsAndBytesConfig. Disable 4-bit so the\n"
    "                        # model loads with its own quantization config.\n"
    "                        load_in_4bit = False\n"
    "\n"
    "                        # Strip vision_config when native quantization is present.\n"
    "                        # Qwen3.5 models with NVFP4/FP8 quantization skip the visual\n"
    "                        # encoder layers, but unsloth still detects vision_config and\n"
    "                        # applies vision-specific patching that produces NaN logits.\n"
    "                        if model_cfg.get(\"vision_config\"):\n"
    "                            del model_cfg[\"vision_config\"]\n"
    "                            model_cfg_path.write_text(json.dumps(model_cfg, indent=2))\n"
    "                            logger.info(\n"
    "                                f\"Stripped vision_config from {model_name} \"\n"
    "                                \"(incompatible with native quantization)\"\n"
    "                            )\n"
    "            except Exception:\n"
    "                pass\n"
    "\n"
    "            # Check if already loaded"
)
content = content.replace(marker, patch)
with open(INFERENCE, "w") as f:
    f.write(content)
print("Patched inference.py: auto-detect native quantization_config")


# ── Patch routes/inference.py: enable reasoning support for Qwen models ──
# The backend hardcodes _sf_supports_reasoning=False for all safetensors
# (non-GGUF) models unless they are gpt-oss Harmony models. This means the
# frontend never sends enable_thinking=false for Qwen3 models even though
# their chat template supports it. Detect enable_thinking in the chat
# template and set supports_reasoning=True when found.

with open(INFERENCE_ROUTES) as f:
    content = f.read()

old = (
    "        # Non-GGUF: gpt-oss Harmony surfaces reasoning via tokenizer-level\n"
    "        # channels; other safetensors reasoning/tools/preserve-thinking\n"
    "        # knobs are not forwarded to tokenizer.apply_chat_template yet, so\n"
    "        # we only advertise support for the Harmony case here.\n"
    "        _sf_supports_reasoning = False\n"
    '        _sf_reasoning_style = "enable_thinking"\n'
    "        if hasattr(backend, \"_is_gpt_oss_model\"):\n"
    "            try:\n"
    "                if backend._is_gpt_oss_model():\n"
    "                    _sf_supports_reasoning = True\n"
    '                    _sf_reasoning_style = "reasoning_effort"\n'
    "            except Exception:\n"
    "                pass"
)
new = (
    "        # Non-GGUF: gpt-oss Harmony surfaces reasoning via tokenizer-level\n"
    "        # channels; other safetensors reasoning/tools/preserve-thinking\n"
    "        # knobs are not forwarded to tokenizer.apply_chat_template yet, so\n"
    "        # we only advertise support for the Harmony case here.\n"
    "        _sf_supports_reasoning = False\n"
    '        _sf_reasoning_style = "enable_thinking"\n'
    "        if hasattr(backend, \"_is_gpt_oss_model\"):\n"
    "            try:\n"
    "                if backend._is_gpt_oss_model():\n"
    "                    _sf_supports_reasoning = True\n"
    '                    _sf_reasoning_style = "reasoning_effort"\n'
    "            except Exception:\n"
    "                pass\n"
    "\n"
    "        # Patch: detect Qwen-style enable_thinking support from the\n"
    "        # chat template. If the template references enable_thinking,\n"
    "        # the model supports the reasoning toggle.\n"
    "        if not _sf_supports_reasoning and _chat_template:\n"
    "            try:\n"
    '                if "enable_thinking" in _chat_template:\n'
    "                    _sf_supports_reasoning = True\n"
    "            except Exception:\n"
    "                pass"
)
if old not in content:
    raise SystemExit(f"ERROR: routes/inference.py marker not found in {INFERENCE_ROUTES}")
content = content.replace(old, new)
with open(INFERENCE_ROUTES, "w") as f:
    f.write(content)
print("Patched routes/inference.py: enable_thinking detection for safetensors models (load path)")

# Second location: the "already_loaded" path has the same issue with its own
# copy of the reasoning-detection logic.
old2 = (
    "                # Non-GGUF: only advertise reasoning for gpt-oss Harmony,\n"
    "                # which emits reasoning via channels at the tokenizer level.\n"
    "                # Template-level chat_template_kwargs (enable_thinking /\n"
    "                # preserve_thinking / tools) are not yet forwarded through\n"
    "                # the transformers generation path, so avoid advertising\n"
    "                # controls the server cannot honour outside GGUF.\n"
    "                _sf_supports_reasoning = False\n"
    '                _sf_reasoning_style = "enable_thinking"\n'
    "                if hasattr(backend, \"_is_gpt_oss_model\"):\n"
    "                    try:\n"
    "                        if backend._is_gpt_oss_model():\n"
    "                            _sf_supports_reasoning = True\n"
    '                            _sf_reasoning_style = "reasoning_effort"\n'
    "                    except Exception:\n"
    "                        pass"
)
new2 = (
    "                # Non-GGUF: only advertise reasoning for gpt-oss Harmony,\n"
    "                # which emits reasoning via channels at the tokenizer level.\n"
    "                # Template-level chat_template_kwargs (enable_thinking /\n"
    "                # preserve_thinking / tools) are not yet forwarded through\n"
    "                # the transformers generation path, so avoid advertising\n"
    "                # controls the server cannot honour outside GGUF.\n"
    "                _sf_supports_reasoning = False\n"
    '                _sf_reasoning_style = "enable_thinking"\n'
    "                if hasattr(backend, \"_is_gpt_oss_model\"):\n"
    "                    try:\n"
    "                        if backend._is_gpt_oss_model():\n"
    "                            _sf_supports_reasoning = True\n"
    '                            _sf_reasoning_style = "reasoning_effort"\n'
    "                    except Exception:\n"
    "                        pass\n"
    "\n"
    "                # Patch: detect Qwen-style enable_thinking support\n"
    "                # from the chat template.\n"
    "                if not _sf_supports_reasoning and _chat_template:\n"
    "                    try:\n"
    '                        if "enable_thinking" in _chat_template:\n'
    "                            _sf_supports_reasoning = True\n"
    "                    except Exception:\n"
    "                        pass"
)
if old2 not in content:
    raise SystemExit(f"ERROR: routes/inference.py already_loaded marker not found in {INFERENCE_ROUTES}")
content = content.replace(old2, new2)
with open(INFERENCE_ROUTES, "w") as f:
    f.write(content)
print("Patched routes/inference.py: enable_thinking detection (already_loaded path)")

# ── Patch main.py: always inject bootstrap credentials ──

with open(MAIN) as f:
    content = f.read()

old = (
    "    if not storage.requires_password_change(storage.DEFAULT_ADMIN_USERNAME):\n"
    "        return html_bytes, None\n"
    "\n"
    '    bootstrap_pw = getattr(app.state, "bootstrap_password", None)'
)
new = (
    "    # Always inject bootstrap credentials when available so the\n"
    "    # frontend can auto-login. After the user changes their password,\n"
    "    # the bootstrap file is deleted and injection stops.\n"
    '    bootstrap_pw = getattr(app.state, "bootstrap_password", None)'
)
if old not in content:
    raise SystemExit(f"ERROR: main.py marker not found in {MAIN}")
content = content.replace(old, new)
with open(MAIN, "w") as f:
    f.write(content)
print("Patched main.py: bootstrap now injects for all modes")


# ── Patch storage.py: must_change_password = False ──

with open(STORAGE) as f:
    content = f.read()

old = "            must_change_password = True,"
new = "            must_change_password = False,"
if old not in content:
    raise SystemExit(f"ERROR: storage.py marker not found in {STORAGE}")
content = content.replace(old, new)
with open(STORAGE, "w") as f:
    f.write(content)
print("Patched storage.py: must_change_password = False")
