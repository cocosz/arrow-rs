#!/usr/bin/env bash
# bloom_verify.sh
#
# Verifies every config directory produced by bloom_regen_opensearch.sh.
# For each config, checks every rewritten parquet file against its NDV/FPP
# using parquet-bloom-info --verify.
#
# Usage:
#   ./bloom_verify.sh [OUTPUT_BASE]
#
# Default:
#   OUTPUT_BASE = ./bloom-data-configs
#
# Exits 0 if all configs pass, 1 if any file fails.

set -euo pipefail

OUTPUT_BASE="${1:-./bloom-data-configs}"
CLICKBENCH_UUID="_DABE_n1Tc-H7ipJc2cIWw"
BINARY="$(dirname "$0")/arrow-rs-bloom/target/release/parquet-bloom-info"

log()  { echo "[bloom_verify] $*"; }
die()  { echo "[bloom_verify] ERROR: $*" >&2; exit 1; }
pass() { echo "[bloom_verify] PASS  $*"; }
fail() { echo "[bloom_verify] FAIL  $*" >&2; }

[[ -x "$BINARY" ]] || die "parquet-bloom-info not found at $BINARY — build it first:
  cargo build --manifest-path arrow-rs-bloom/parquet/Cargo.toml \\
      --features arrow,cli --bin parquet-bloom-info --release"

[[ -d "$OUTPUT_BASE" ]] || die "Output base '$OUTPUT_BASE' does not exist"

PARQUET_SUBDIR="nodes/0/indices/$CLICKBENCH_UUID/0/parquet"

TOTAL_CONFIGS=0
TOTAL_FILES=0
FAILED_FILES=0
FAILED_LIST=()

log "Scanning configs under: $OUTPUT_BASE"
log ""

# ── For each config directory ─────────────────────────────────────────────────
for CONFIG_DIR in "$OUTPUT_BASE"/ndv_*__fpp_*/; do
    [[ -d "$CONFIG_DIR" ]] || continue
    TOTAL_CONFIGS=$(( TOTAL_CONFIGS + 1 ))

    CONFIG_NAME=$(basename "$CONFIG_DIR")
    MANIFEST="$CONFIG_DIR/bloom_config.txt"

    # Read NDV and FPP from the manifest written by bloom_regen_opensearch.sh
    if [[ ! -f "$MANIFEST" ]]; then
        fail "$CONFIG_NAME — bloom_config.txt not found, skipping"
        continue
    fi

    NDV=$(grep "^bloom_filter_ndv=" "$MANIFEST" | cut -d= -f2)
    FPP=$(grep "^bloom_filter_fpp=" "$MANIFEST" | cut -d= -f2)

    if [[ -z "$NDV" || -z "$FPP" ]]; then
        fail "$CONFIG_NAME — could not read NDV/FPP from manifest"
        continue
    fi

    PARQUET_DIR="$CONFIG_DIR/$PARQUET_SUBDIR"
    if [[ ! -d "$PARQUET_DIR" ]]; then
        fail "$CONFIG_NAME — parquet dir not found: $PARQUET_DIR"
        FAILED_FILES=$(( FAILED_FILES + 1 ))
        FAILED_LIST+=("$CONFIG_NAME (missing parquet dir)")
        continue
    fi

    mapfile -t FILES < <(find "$PARQUET_DIR" -maxdepth 1 -name "*.parquet" | sort)
    FILE_COUNT=${#FILES[@]}

    log "[$CONFIG_NAME]  NDV=$NDV  FPP=$FPP  ($FILE_COUNT files)"

    CONFIG_FAILED=0
    for F in "${FILES[@]}"; do
        FNAME=$(basename "$F")
        TOTAL_FILES=$(( TOTAL_FILES + 1 ))

        # Run verify; capture output and exit code
        VERIFY_OUT=$("$BINARY" --verify --ndv "$NDV" --fpp "$FPP" "$F" 2>&1)
        VERIFY_EXIT=$?

        if [[ $VERIFY_EXIT -eq 0 ]]; then
            pass "  $FNAME"
        else
            fail "  $FNAME"
            # Print the detailed output so you can see which columns failed
            echo "$VERIFY_OUT" | grep -E "(MISMATCH|FAILED|column)" | sed 's/^/      /'
            FAILED_FILES=$(( FAILED_FILES + 1 ))
            CONFIG_FAILED=$(( CONFIG_FAILED + 1 ))
            FAILED_LIST+=("$CONFIG_NAME / $FNAME")
        fi
    done

    if [[ $CONFIG_FAILED -eq 0 ]]; then
        log "  → all $FILE_COUNT files OK"
    else
        log "  → $CONFIG_FAILED/$FILE_COUNT files FAILED"
    fi
    log ""
done

# ── Summary ───────────────────────────────────────────────────────────────────
log "============================================"
log "Configs checked : $TOTAL_CONFIGS"
log "Files checked   : $TOTAL_FILES"
log "Files failed    : $FAILED_FILES"
log "============================================"

if [[ $FAILED_FILES -gt 0 ]]; then
    log ""
    log "Failed files:"
    for entry in "${FAILED_LIST[@]}"; do
        log "  ✗ $entry"
    done
    exit 1
else
    log "All files PASSED verification."
    exit 0
fi
