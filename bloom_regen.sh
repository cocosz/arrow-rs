#!/usr/bin/env bash
# bloom_regen.sh — Build parquet-rewrite-bloom on EC2 and regenerate
# ClickBench Parquet files for every (NDV, FPP) combination.
#
# Usage:
#   ./bloom_regen.sh [SOURCE_DIR] [OUTPUT_BASE_DIR]
#
# Defaults:
#   SOURCE_DIR      = ./hits_parquet          (directory of source .parquet files)
#   OUTPUT_BASE_DIR = ./bloom_data            (parent dir; subdirs created per config)
#
# Each output subdir is named:  ndv_<NDV>__fpp_<FPP>/
# e.g.  bloom_data/ndv_100000__fpp_0.05/
#
# Prerequisites (handled automatically if missing):
#   - Rust / cargo  (installed via rustup if absent)
#   - The cocosz/arrow-rs bloom-rewrite-tool branch (cloned if absent)
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Configurable NDV / FPP matrix ────────────────────────────────────────────
NDV_VALUES=(100000 500000 1000000 5000000)
FPP_VALUES=(0.001 0.01 0.05)
# ─────────────────────────────────────────────────────────────────────────────

SOURCE_DIR="${1:-./hits_parquet}"
OUTPUT_BASE="${2:-./bloom_data}"
REPO_DIR="./arrow-rs-bloom"
BINARY=""

log()  { echo "[bloom_regen] $*"; }
die()  { echo "[bloom_regen] ERROR: $*" >&2; exit 1; }

# ── 1. Install Rust if needed ─────────────────────────────────────────────────
if ! command -v cargo &>/dev/null && [[ ! -f "$HOME/.cargo/bin/cargo" ]]; then
    log "cargo not found — installing Rust via rustup (no-modify-path, toolchain=1.91)"
    curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain 1.91
fi

# Source cargo env (covers both fresh installs and pre-existing setups)
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
export PATH="$HOME/.cargo/bin:$PATH"

cargo --version >/dev/null 2>&1 || die "cargo still not available after install attempt"
log "Using $(cargo --version)"

# ── 2. Clone / update the repo ────────────────────────────────────────────────
if [[ ! -d "$REPO_DIR" ]]; then
    log "Cloning cocosz/arrow-rs branch bloom-rewrite-tool → $REPO_DIR"
    git clone --depth 1 --branch bloom-rewrite-tool \
        https://github.com/cocosz/arrow-rs.git "$REPO_DIR"
else
    log "Repo already present at $REPO_DIR — pulling latest"
    git -C "$REPO_DIR" pull --ff-only
fi

# ── 3. Build the binary (release for speed) ───────────────────────────────────
log "Building parquet-rewrite-bloom (release)…"
cargo build \
    --manifest-path "$REPO_DIR/parquet/Cargo.toml" \
    --features arrow,cli \
    --bin parquet-rewrite-bloom \
    --release 2>&1

BINARY="$REPO_DIR/target/release/parquet-rewrite-bloom"
[[ -x "$BINARY" ]] || die "Binary not found at $BINARY"
log "Binary ready: $BINARY"

# ── 4. Discover source files ──────────────────────────────────────────────────
[[ -d "$SOURCE_DIR" ]] || die "Source directory '$SOURCE_DIR' does not exist"

mapfile -t SOURCE_FILES < <(find "$SOURCE_DIR" -maxdepth 1 -name "*.parquet" | sort)
[[ ${#SOURCE_FILES[@]} -gt 0 ]] || die "No .parquet files found in '$SOURCE_DIR'"
log "Found ${#SOURCE_FILES[@]} source file(s) in $SOURCE_DIR"

# ── 5. Dry-run to print detected bloom columns (once, on first file) ──────────
log "Detected bloom-filter columns in source:"
"$BINARY" --input "${SOURCE_FILES[0]}" --dry-run 2>&1 | sed 's/^/    /'

# ── 6. Generate all configurations ───────────────────────────────────────────
TOTAL=$(( ${#NDV_VALUES[@]} * ${#FPP_VALUES[@]} ))
CONFIG_IDX=0

for NDV in "${NDV_VALUES[@]}"; do
    for FPP in "${FPP_VALUES[@]}"; do
        CONFIG_IDX=$(( CONFIG_IDX + 1 ))
        TAG="ndv_${NDV}__fpp_${FPP}"
        OUT_DIR="$OUTPUT_BASE/$TAG"

        log "[$CONFIG_IDX/$TOTAL] NDV=$NDV  FPP=$FPP  → $OUT_DIR"
        mkdir -p "$OUT_DIR"

        FILE_IDX=0
        for SRC in "${SOURCE_FILES[@]}"; do
            FILE_IDX=$(( FILE_IDX + 1 ))
            FNAME=$(basename "$SRC")
            DEST="$OUT_DIR/$FNAME"

            if [[ -f "$DEST" ]]; then
                log "  [$FILE_IDX/${#SOURCE_FILES[@]}] $FNAME — already exists, skipping"
                continue
            fi

            log "  [$FILE_IDX/${#SOURCE_FILES[@]}] $FNAME"
            "$BINARY" \
                --input  "$SRC" \
                --output "$DEST" \
                --bloom-filter-ndv "$NDV" \
                --bloom-filter-fpp "$FPP" \
                2>&1 | grep -E "^(Bloom|Wrote)" | sed 's/^/    /'
        done

        # Write a manifest so the config is self-documenting
        cat > "$OUT_DIR/bloom_config.txt" <<EOF
bloom_filter_ndv=$NDV
bloom_filter_fpp=$FPP
source_dir=$(realpath "$SOURCE_DIR")
generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
files=${#SOURCE_FILES[@]}
EOF
        log "  wrote $OUT_DIR/bloom_config.txt"
    done
done

# ── 7. Summary ────────────────────────────────────────────────────────────────
log ""
log "Done. Output layout:"
find "$OUTPUT_BASE" -name "bloom_config.txt" | sort | while read -r cfg; do
    dir=$(dirname "$cfg")
    count=$(find "$dir" -name "*.parquet" | wc -l | tr -d ' ')
    log "  $dir  ($count parquet files)"
done
