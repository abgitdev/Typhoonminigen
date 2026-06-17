#!/bin/bash
# Mistral-24B fuse check.
#
# The flux-2-swift-mlx engine still contains the full Mistral-Small-3.2-24B VLM
# code; it downloads (~24 GB) and loads only through three doors, all of which
# this app keeps closed. On a 16-32 GB Mac an accidental Mistral load means
# swap-freeze. This script fails the build/CI if any fuse is touched.
#
# Doors (engine Flux2Pipeline.swift):
#   1. model == .dev        -> Mistral is the Dev text encoder
#   2. interpretImagePaths  -> Klein "interpret" branch loads Mistral
#   3. Klein I2I + upsamplePrompt -> upsample-with-images loads Mistral
#
# Run from the repo root: tools/check_mistral_fuses.sh
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="Sources/Typhoonminigen"
fail=0
err() { echo "❌ FUSE BROKEN: $1"; fail=1; }
ok()  { echo "✅ $1"; }

# ── Fuse 1: ModelTier exposes ONLY the two Klein tiers (no .dev) ─────────────
tiers=$(grep -E '^\s*case [a-zA-Z0-9]+$' "$SRC/Models/ModelTier.swift" | awk '{print $2}' | sort | tr '\n' ' ')
if [ "$tiers" = "klein4B klein9B " ]; then
    ok "ModelTier cases = klein4B + klein9B only"
else
    err "ModelTier enum cases changed: '$tiers' (expected exactly: klein4B klein9B)"
fi

# ── Fuse 1b: the pipeline is always constructed with an explicit model ───────
# (Flux2Pipeline() DEFAULTS to .dev — an argless init would silently pick Mistral.)
if grep -q 'model: tier.flux2Model' "$SRC/Services/FluxEngine.swift"; then
    ok "Flux2Pipeline gets an explicit model: (engine default is .dev)"
else
    err "FluxEngine no longer passes 'model: tier.flux2Model' to Flux2Pipeline"
fi

# ── Fuse 2: interpretImagePaths is a nil literal at every engine call ────────
bad=$(grep -n 'interpretImagePaths:' "$SRC/Services/FluxEngine.swift" | grep -v 'interpretImagePaths: nil')
if [ -z "$bad" ]; then
    n=$(grep -c 'interpretImagePaths: nil' "$SRC/Services/FluxEngine.swift")
    if [ "$n" -ge 2 ]; then
        ok "interpretImagePaths: nil at all $n engine call sites"
    else
        err "expected >=2 'interpretImagePaths: nil' call sites in FluxEngine, found $n"
    fi
else
    err "non-nil interpretImagePaths in FluxEngine: $bad"
fi
# ...and the field must not exist anywhere else in the app (deleted in v0.30).
stray=$(grep -rn 'interpretImagePaths' "$SRC" --include='*.swift' | grep -v 'Services/FluxEngine.swift')
if [ -z "$stray" ]; then
    ok "no interpretImagePaths outside FluxEngine"
else
    err "interpretImagePaths leaked outside FluxEngine: $stray"
fi

# ── Fuse 3: upsample is impossible with references (both layers) ─────────────
if grep -q 'if !referenceImages.isEmpty { req.upsamplePrompt = false }' "$SRC/Services/FluxEngine.swift"; then
    ok "FluxEngine forces upsamplePrompt=false when references are present"
else
    err "FluxEngine guard 'if !referenceImages.isEmpty { req.upsamplePrompt = false }' missing"
fi
if grep -q 'upsamplePrompt: upsamplePrompt && references.isEmpty' "$SRC/ViewModels/GenerateViewModel.swift"; then
    ok "GenerateViewModel sends upsample only when references are empty"
else
    err "GenerateViewModel guard 'upsamplePrompt && references.isEmpty' missing"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "All Mistral fuses intact — the 24 GB VLM is unreachable from the app."
else
    echo "FUSES BROKEN — do not ship. See lines above."
fi
exit "$fail"
