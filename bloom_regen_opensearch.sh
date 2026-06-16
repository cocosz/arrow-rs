#!/usr/bin/env bash
# bloom_regen_opensearch.sh
#
# Regenerates ClickBench parquet files with different Bloom filter NDV/FPP
# settings, preserving the full OpenSearch data-node directory tree.
#
# Only the clickbench index parquet files are rewritten. All other indices
# (fresh-bloom, test-idx2, test-nosort) and all non-parquet files (Lucene
# segments, translog, _state, node.lock) are hard-linked — zero extra disk.
#
# Source layout:
#   <SOURCE_ROOT>/nodes/0/indices/_DABE_n1Tc-H7ipJc2cIWw/0/parquet/*.parquet
#
# Output layout (one tree per config):
#   <OUTPUT_BASE>/ndv_<NDV>__fpp_<FPP>/nodes/0/...   (full OpenSearch data dir)
#
# Usage:
#   ./bloom_regen_opensearch.sh [SOURCE_ROOT] [OUTPUT_BASE]
#
# Defaults:
#   SOURCE_ROOT = ./bloom-data
#   OUTPUT_BASE = ./bloom-data-configs
#
# Set SKIP_BUILD=1 to skip cargo build if binary already exists.

set -euo pipefail

# ── NDV / FPP matrix ──────────────────────────────────────────────────────────
CONFIGS=(
    "100000  0.2"
    "100000  0.1"
    "100000  0.05"
    "100000  0.01"
    "500000  0.2"
    "500000  0.1"
    "500000  0.05"
    "500000  0.01"
    "1000000 0.2"
    "1000000 0.1"
    "1000000 0.05"
    "1000000 0.01"
)

# UUID of the clickbench index (the only one with real data to rewrite)
CLICKBENCH_UUID="_DABE_n1Tc-H7ipJc2cIWw"
# ─────────────────────────────────────────────────────────────────────────────

SOURCE_ROOT="${1:-./bloom-data}"
OUTPUT_BASE="${2:-./bloom-data-configs}"
REPO_DIR="./arrow-rs-bloom"
SKIP_BUILD="${SKIP_BUILD:-0}"

log()  { echo "[bloom_regen] $*"; }
die()  { echo "[bloom_regen] ERROR: $*" >&2; exit 1; }

# ── 1. Rust / cargo ───────────────────────────────────────────────────────────
if ! command -v cargo &>/dev/null; then
    [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env" || true
fi
if ! command -v cargo &>/dev/null; then
    log "cargo not found — installing Rust 1.91 via rustup"
    curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain 1.91
    source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$PATH"
cargo --version >/dev/null 2>&1 || die "cargo not available"
log "Rust: $(cargo --version)"

# ── 2. Clone / update repo ────────────────────────────────────────────────────
if [[ ! -d "$REPO_DIR" ]]; then
    log "Cloning cocosz/arrow-rs (branch bloom-rewrite-tool) → $REPO_DIR"
    git clone --depth 1 --branch bloom-rewrite-tool \
        https://github.com/cocosz/arrow-rs.git "$REPO_DIR"
else
    log "Repo already at $REPO_DIR"
    git -C "$REPO_DIR" fetch origin
    git -C "$REPO_DIR" reset --hard origin/bloom-rewrite-tool
fi

# ── 3. Build binary ───────────────────────────────────────────────────────────
BINARY="$REPO_DIR/target/release/parquet-rewrite-bloom"
VERIFY_BIN="$REPO_DIR/target/release/parquet-bloom-info"
if [[ "$SKIP_BUILD" == "1" && -x "$BINARY" && -x "$VERIFY_BIN" ]]; then
    log "SKIP_BUILD=1 — reusing existing binaries at $BINARY"
else
    log "Building parquet-rewrite-bloom and parquet-bloom-info (release)…"
    cargo build \
        --manifest-path "$REPO_DIR/parquet/Cargo.toml" \
        --features arrow,cli \
        --bin parquet-rewrite-bloom \
        --bin parquet-bloom-info \
        --release 2>&1
    [[ -x "$BINARY" ]]     || die "parquet-rewrite-bloom not found after build"
    [[ -x "$VERIFY_BIN" ]] || die "parquet-bloom-info not found after build"
fi
log "Rewrite binary : $BINARY"
log "Verify binary  : $VERIFY_BIN"

# ── 4. Validate source and locate clickbench parquet dir ─────────────────────
[[ -d "$SOURCE_ROOT" ]] || die "Source root '$SOURCE_ROOT' does not exist"

CB_PARQUET_DIR="$SOURCE_ROOT/nodes/0/indices/$CLICKBENCH_UUID/0/parquet"
[[ -d "$CB_PARQUET_DIR" ]] || die "clickbench parquet dir not found: $CB_PARQUET_DIR"

mapfile -t SRC_FILES < <(find "$CB_PARQUET_DIR" -maxdepth 1 -name "*.parquet" | sort)
[[ ${#SRC_FILES[@]} -gt 0 ]] || die "No .parquet files in $CB_PARQUET_DIR"

log "clickbench index UUID : $CLICKBENCH_UUID"
log "Parquet files found   : ${#SRC_FILES[@]}"
for f in "${SRC_FILES[@]}"; do
    log "  $(basename "$f")  ($(du -h "$f" | cut -f1))"
done

# Dry-run to confirm bloom columns
log ""
log "Bloom-filter columns in source (dry-run):"
"$BINARY" --input "${SRC_FILES[0]}" --dry-run 2>&1 | sed 's/^/  /'

# ── 5. Generate one output tree per config ────────────────────────────────────
TOTAL=${#CONFIGS[@]}
IDX=0

for CFG in "${CONFIGS[@]}"; do
    IDX=$(( IDX + 1 ))
    read -r NDV FPP <<< "$CFG"
    TAG="ndv_${NDV}__fpp_${FPP}"
    CONFIG_ROOT="$OUTPUT_BASE/$TAG"

    log ""
    log "[$IDX/$TOTAL] NDV=$NDV  FPP=$FPP  →  $CONFIG_ROOT"

    # ── Skip entire config if already fully generated ─────────────────────────
    DEST_PARQUET_DIR="$CONFIG_ROOT/nodes/0/indices/$CLICKBENCH_UUID/0/parquet"
    MANIFEST="$CONFIG_ROOT/bloom_config.txt"
    if [[ -f "$MANIFEST" ]]; then
        EXISTING=$(find "$DEST_PARQUET_DIR" -maxdepth 1 -name "*.parquet" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$EXISTING" -eq "${#SRC_FILES[@]}" ]]; then
            log "  Already complete ($EXISTING/${#SRC_FILES[@]} files) — skipping"
            continue
        else
            log "  Partially complete ($EXISTING/${#SRC_FILES[@]} files) — resuming"
        fi
    fi

    # ── 5a. Mirror full source tree: hard-link everything except clickbench parquets
    log "  Mirroring source tree (hard-links for all non-parquet + other indices)…"
    mkdir -p "$CONFIG_ROOT"
    if command -v rsync &>/dev/null; then
        # Hard-link all files; exclude only the clickbench parquet files — we'll
        # write those ourselves below.
        rsync -a \
            --link-dest="$(realpath "$SOURCE_ROOT")" \
            --exclude="nodes/0/indices/$CLICKBENCH_UUID/0/parquet/*.parquet" \
            "$SOURCE_ROOT/" "$CONFIG_ROOT/"
    else
        # Fallback: cp -al everything then delete the clickbench parquet hard-links
        rm -rf "$CONFIG_ROOT"
        cp -al "$SOURCE_ROOT" "$CONFIG_ROOT"
        find "$CONFIG_ROOT/nodes/0/indices/$CLICKBENCH_UUID/0/parquet" \
            -maxdepth 1 -name "*.parquet" -delete
    fi

    # Ensure destination parquet dir exists (rsync with --exclude may skip it)
    mkdir -p "$DEST_PARQUET_DIR"

    # ── 5b. Rewrite each clickbench parquet file
    FILE_IDX=0
    for SRC in "${SRC_FILES[@]}"; do
        FILE_IDX=$(( FILE_IDX + 1 ))
        FNAME=$(basename "$SRC")
        DEST="$DEST_PARQUET_DIR/$FNAME"

        if [[ -f "$DEST" ]]; then
            log "  [$FILE_IDX/${#SRC_FILES[@]}] $FNAME — already exists, skipping"
            continue
        fi

        SIZE=$(du -h "$SRC" | cut -f1)
        log "  [$FILE_IDX/${#SRC_FILES[@]}] $FNAME  ($SIZE)"
        "$BINARY" \
            --input  "$SRC" \
            --output "$DEST" \
            --bloom-filter-ndv "$NDV" \
            --bloom-filter-fpp "$FPP" \
            2>&1 | grep -E "^(Bloom|Wrote)" | sed 's/^/      /'

        # ── Verify bloom filter lengths match expected NDV/FPP
        # Run once, capture output + exit code. set -e is bypassed by `|| true`.
        VERIFY_OUT=$("$VERIFY_BIN" --verify --ndv "$NDV" --fpp "$FPP" "$DEST" 2>&1) || true
        echo "$VERIFY_OUT" | grep -E "(OK|MISMATCH|PASSED|FAILED)" | sed 's/^/      /'
        if echo "$VERIFY_OUT" | grep -q "FAILED"; then
            die "Bloom filter verification failed for $DEST"
        fi
    done

    # ── 5c. Manifest
    cat > "$CONFIG_ROOT/bloom_config.txt" <<EOF
bloom_filter_ndv=$NDV
bloom_filter_fpp=$FPP
clickbench_uuid=$CLICKBENCH_UUID
source_root=$(realpath "$SOURCE_ROOT")
generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
parquet_files=${#SRC_FILES[@]}
EOF
    log "  wrote bloom_config.txt"
done

# ── 6. Summary ────────────────────────────────────────────────────────────────
log ""
log "Done. Output: $OUTPUT_BASE"
log ""
printf "  %-30s  %6s  %s\n" "config" "files" "parquet dir size"
printf "  %-30s  %6s  %s\n" "------" "-----" "----------------"
for CFG in "${CONFIGS[@]}"; do
    read -r NDV FPP <<< "$CFG"
    TAG="ndv_${NDV}__fpp_${FPP}"
    DIR="$OUTPUT_BASE/$TAG/nodes/0/indices/$CLICKBENCH_UUID/0/parquet"
    COUNT=$(find "$DIR" -name "*.parquet" 2>/dev/null | wc -l | tr -d ' ')
    SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1 || echo "?")
    printf "  %-30s  %6s  %s\n" "$TAG" "$COUNT" "$SIZE"
done
log ""
log "To benchmark a config, stop OpenSearch, set path.data in opensearch.yml to:"
log "  $(realpath "$OUTPUT_BASE")/<tag>"
log "then restart OpenSearch."
