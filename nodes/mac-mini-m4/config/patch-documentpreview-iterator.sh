#!/bin/bash
# Patch pdf.js's unguarded `Iterator.prototype.join` probe in the shipped
# documentpreview client bundle — mac-mini-m4.
#
# Usage:
#   bash nodes/mac-mini-m4/config/patch-documentpreview-iterator.sh
#   bash nodes/mac-mini-m4/config/patch-documentpreview-iterator.sh --revert
#
# ── The bug ────────────────────────────────────────────────────────────────
# pdf.js 6.3.289 ships this line (src/shared/util.js, "TODO: Remove this once
# `Iterator.prototype.join` is generally available"):
#
#     if (typeof Iterator.prototype.join !== "function") {
#       Iterator.prototype.join = function (separator) { return [...this].join(separator) }
#     }
#
# `Iterator` is a *global introduced by the iterator-helpers proposal*, not a
# long-standing built-in. Where the global is absent, the expression
# `Iterator.prototype` is a member access on an UNDECLARED identifier, so it
# throws a ReferenceError *before* `typeof` can make it safe:
#
#     typeof Undeclared          -> "undefined"   (typeof is safe)
#     typeof Undeclared.proto    -> ReferenceError (property access happens first)
#
# The throw happens at module-evaluation time, which is why the whole plugin
# fails to import and the GUI logs:
#
#     failed to import loader entry ... (dsh-client-ui-sidebar-documentpreview):
#     Iterator is not defined
#
# ── Who is affected ────────────────────────────────────────────────────────
# The `Iterator` global requires Safari 18.4+, Chrome 122+, or Firefox 131+.
# Newer browsers never hit the line. Older ones — including any Safari before
# 18.4, which is most Macs and every iPhone/iPad below iOS 18.4 — throw and
# lose the document-preview plugin.
#
# This is NOT caused by LAN exposure. Binding 0.0.0.0 only changes who may
# connect; the same browser hits the same bug on http://127.0.0.1. It surfaces
# in LAN use simply because a phone or an older browser is the typical *second*
# client, while the host itself runs a current Chrome/Safari.
#
# ── The fix ────────────────────────────────────────────────────────────────
# Guard the probe so the global is never dereferenced when absent:
#
#   before: typeof Iterator.prototype.join !== "function"
#   after : typeof globalThis.Iterator !== "undefined" && typeof Iterator.prototype.join !== "function"
#
# `typeof globalThis.Iterator` is always safe (globalThis exists in every
# target and the typeof guards the property read); `&&` short-circuits, so the
# throwing member access is never evaluated on engines without the global.
# Behaviour on modern browsers is unchanged: the polyfill is still installed
# only when `join` is genuinely missing.
#
# ── Why patch the installed file ───────────────────────────────────────────
# The defect is upstream and still present in pdf.js master, so there is no
# fixed release to upgrade to. The bundle is a prebuilt artifact inside the dsh
# installation; this repo tracks the correction so a reinstall can re-apply it.
#
# IMPORTANT: `npm i -g @deepseek-ai/dsh` (or any reinstall) replaces the file and
# silently drops this fix. Re-run this script after upgrading dsh, and re-check
# it if the document-preview plugin starts failing again.

set -euo pipefail

REVERT=0
[[ "${1:-}" == "--revert" ]] && REVERT=1

DSH_ROOT="${DSH_ROOT:-/opt/homebrew/lib/node_modules/@deepseek-ai/dsh}"
TARGET="${DSH_ROOT}/node_modules/@deepseek-ai/dsh-web-app/node_modules/@deepseek-ai/dsh-client-ui-sidebar-documentpreview/lib/client.js"

# The probe appears in TWO structurally different shapes, and each needs its own
# replacement because the guard must sit in a different place:
#
#   1. readable, module body:
#        if (typeof Iterator.prototype.join !== "function") Iterator.prototype.join = …
#      -> prepend the global test to the same `if` condition.
#
#   2. minified, escaped inside the template string carrying the pdf.js worker:
#        "function"!=typeof Iterator.prototype.join&&(Iterator.prototype.join=…
#      -> rewrite the whole leading condition. Note the test must become
#         `"undefined"!=typeof globalThis.Iterator && "function"!=typeof Iterator.prototype.join`
#         — putting the global test first so `&&` short-circuits BEFORE the
#         throwing property read. A naive `&& typeof Iterator.prototype.join`
#         would still evaluate the member access and still throw.
#
# Both replacements below were checked against a truth table over
# (Iterator global present × join present): the polyfill installs only when the
# global exists AND join is missing, and nothing is evaluated when it is absent.
#
# `\"` in the escaped form is the literal backslash-quote the bundle contains
# (the worker source is embedded in a double-quoted JS string). These are matched
# as plain text — no regex, no unescaping — and inside a single-quoted shell
# string a lone backslash stays a lone backslash, which is what the file has.
READABLE_ORIGINAL='if (typeof Iterator.prototype.join !== "function") Iterator.prototype.join'
READABLE_PATCHED='if (typeof globalThis.Iterator !== "undefined" && typeof Iterator.prototype.join !== "function") Iterator.prototype.join'
ESCAPED_ORIGINAL='\"function\"!=typeof Iterator.prototype.join&&(Iterator.prototype.join'
ESCAPED_PATCHED='\"undefined\"!=typeof globalThis.Iterator&&\"function\"!=typeof Iterator.prototype.join&&(Iterator.prototype.join'

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: target bundle not found:" >&2
    echo "       ${TARGET}" >&2
    echo "       Is dsh installed at ${DSH_ROOT}? Override with DSH_ROOT=..." >&2
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${TARGET}.orig-${STAMP}"

if [[ "$REVERT" -eq 1 ]]; then
    LATEST="$(ls -t "${TARGET}".orig-* 2>/dev/null | head -1 || true)"
    if [[ -z "$LATEST" ]]; then
        echo "ERROR: no .orig-* backup to restore from beside ${TARGET}" >&2
        exit 1
    fi
    cp "$LATEST" "$TARGET"
    log "reverted from ${LATEST}"
    exit 0
fi

# Idempotence: a second run must not double-patch.
if grep -q 'globalThis.Iterator' "$TARGET"; then
    log "already patched — nothing to do"
    exit 0
fi

# Require BOTH shapes to be present before touching anything. If pdf.js is
# upgraded and either shape changes, this fails loudly instead of silently
# applying a partial fix.
for pair in \
    "readable|${READABLE_ORIGINAL}" \
    "escaped|${ESCAPED_ORIGINAL}"; do
    label="${pair%%|*}"; needle="${pair#*|}"
    if ! grep -qF "$needle" "$TARGET"; then
        echo "ERROR: ${label} probe not found — bundle layout changed (pdf.js upgraded?)." >&2
        echo "       Inspect manually:  grep -o 'Iterator.prototype.join' ${TARGET}" >&2
        exit 1
    fi
done

cp "$TARGET" "$BACKUP"
log "backed up -> ${BACKUP}"

# Literal, non-regex substitution in Python: the surrounding code contains
# regex metacharacters, and a plain string replace is safer and easier to audit.
python3 - "$TARGET" \
    "$READABLE_ORIGINAL" "$READABLE_PATCHED" \
    "$ESCAPED_ORIGINAL" "$ESCAPED_PATCHED" <<'PY'
import sys
path, r_old, r_new, e_old, e_new = sys.argv[1:6]
with open(path, "r", encoding="utf-8") as fh:
    src = fh.read()

readable_hits = src.count(r_old)
src = src.replace(r_old, r_new)

escaped_hits = src.count(e_old)
src = src.replace(e_old, e_new)

with open(path, "w", encoding="utf-8") as fh:
    fh.write(src)

print(f"  readable probe replacements : {readable_hits}")
print(f"  escaped  probe replacements : {escaped_hits}")
# Both shapes were confirmed present above, so a zero here means the
# replacement strings were edited inconsistently with the originals.
if readable_hits == 0 or escaped_hits == 0:
    sys.exit("ERROR: a replacement matched nothing — originals/patched strings disagree")
PY

# ── Validate ───────────────────────────────────────────────────────────────
# 1. Node must be able to parse the module (catches a broken substitution).
#    `node --check <file>` parses that file with its own goal; feeding the
#    source on stdin instead misparses it, because a bundle declares ESM
#    exports and stdin carries no filename to infer the module goal from.
#    Keep the path form.
# 2. The unguarded probe must be gone everywhere.
if ! node --check "$TARGET" 2>/dev/null; then
    echo "ERROR: patched file does not parse — restoring backup" >&2
    node --check "$TARGET" >&2 || true
    cp "$BACKUP" "$TARGET"
    exit 1
fi

# Post-check must be POSITIVE, not "is the old text gone".
#
# The escaped old form is a strict substring of the escaped new form (the new
# text keeps the original `\"function\"!=typeof Iterator.prototype.join&&(…`
# tail and prepends the global test), so asserting "old absent" can never pass
# there. Assert the patched text instead: exactly one of each new phrase, and
# exactly two `globalThis.Iterator` guards — one per probe site.
R_NEW_COUNT=$(grep -oF "$READABLE_PATCHED" "$TARGET" | wc -l | tr -d ' ')
E_NEW_COUNT=$(grep -oF "$ESCAPED_PATCHED" "$TARGET" | wc -l | tr -d ' ')
GUARDS=$(grep -oF 'globalThis.Iterator' "$TARGET" | wc -l | tr -d ' ')

if [[ "$R_NEW_COUNT" -ne 1 || "$E_NEW_COUNT" -ne 1 || "$GUARDS" -ne 2 ]]; then
    echo "ERROR: post-check failed (readable=${R_NEW_COUNT} escaped=${E_NEW_COUNT} guards=${GUARDS}, expected 1/1/2) — restoring backup" >&2
    cp "$BACKUP" "$TARGET"
    exit 1
fi

log "patched and validated: ${TARGET}"
cat <<EOF

=== documentpreview Iterator fix applied ===
  Target : ${TARGET}
  Backup : ${BACKUP}

Restart the dsh Web GUI (Ctrl-C, then \`dsh web\`) and reload the page in the
browser that showed the error. Hard-refresh (Ctrl+Shift+R / Cmd+Shift+R) so the
client does not reuse the cached bundle.

To undo:
  bash ${BASH_SOURCE[0]} --revert

NOTE: reinstalling or upgrading dsh replaces this file and drops the fix.
      Re-run this script afterwards.
EOF