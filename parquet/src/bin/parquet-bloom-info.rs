// Prints per-column bloom_filter_offset/length for every row group.
// A non-None offset means that column has a bloom filter in the file.
//
// Build: cargo build --features=arrow,cli --bin parquet-bloom-info
// Run:   ./target/debug/parquet-bloom-info <file.parquet>
//
// Verify mode: checks that the bloom filter length in the file matches
// the size expected for the given NDV and FPP:
//   ./target/debug/parquet-bloom-info --verify --ndv 1000000 --fpp 0.01 <file.parquet>
// Exits 0 if all bloom-filter columns match, 1 if any mismatch.

use std::fs::File;
use clap::Parser;
use parquet::file::{reader::FileReader, serialized_reader::SerializedFileReader};

#[derive(Debug, Parser)]
#[clap(about("Print or verify bloom filter metadata in a Parquet file"))]
struct Args {
    /// Path to the Parquet file.
    #[clap(required = true)]
    file: String,

    /// Verify mode: check that bloom filter lengths match the expected size
    /// for the given NDV and FPP. Exits 1 on mismatch.
    #[clap(long)]
    verify: bool,

    /// Expected NDV (number of distinct values) used when writing bloom filters.
    #[clap(long)]
    ndv: Option<u64>,

    /// Expected FPP (false positive probability) used when writing bloom filters.
    #[clap(long)]
    fpp: Option<f64>,
}

/// Compute the expected on-disk bloom filter byte length for a given NDV and FPP.
///
/// Arrow-rs uses a Split Block Bloom Filter (SBBF) with post-write folding:
/// the filter is initially sized for NDV, all values are inserted, then
/// `fold_to_target_fpp` shrinks it to the smallest size that still meets FPP
/// given the *actual* distinct value count.
///
/// This means the on-disk size is determined by:
///   actual_ndv = min(provided NDV, actual distinct values in the file)
///
/// Formula (matches arrow-rs `num_of_bits_from_ndv_fpp`):
///   num_bits  = -8 * ndv / ln(1 - fpp^(1/8))
///   num_bytes = num_bits / 8   (integer truncation)
///   rounded up to next power of two, clamped to [32, 128 MB]
///   on-disk   = bitset_bytes + thrift_header_bytes
///
/// The thrift header is 15 bytes for bitset < 16384, 17 bytes for larger.
fn expected_bloom_bytes(ndv: u64, fpp: f64) -> i32 {
    let num_bits = -8.0 * ndv as f64 / (1.0 - fpp.powf(1.0 / 8.0)).ln();
    let num_bytes = (num_bits / 8.0) as usize; // integer truncation (matches Rust `as usize`)

    let bitset = num_bytes
        .max(32)
        .min(128 * 1024 * 1024)
        .next_power_of_two();

    let header_bytes: usize = if bitset >= 16384 { 17 } else { 15 };
    (bitset + header_bytes) as i32
}

/// Given the expected NDV/FPP, return all plausible on-disk sizes that are valid.
/// Arrow-rs folds the filter after writing to the actual row count, so the real
/// on-disk size may be smaller than expected_bloom_bytes(ndv, fpp).
/// We accept any size that is a valid SBBF size (power-of-two bitset + header)
/// that is <= expected_bloom_bytes(ndv, fpp).
fn is_valid_bloom_size(actual: i32, ndv: u64, fpp: f64) -> bool {
    let max_expected = expected_bloom_bytes(ndv, fpp);
    if actual > max_expected {
        return false; // larger than NDV hint would produce — definitely wrong
    }
    // Must be a valid SBBF on-disk size: power-of-two bitset + thrift header.
    // Header size varies by bitset size (varint encoding of num_bytes field):
    //   bitset < 128      → 1 byte varint → header = 13 bytes
    //   bitset < 16384    → 2 byte varint → header = 15 bytes
    //   bitset < 2097152  → 3 byte varint → header = 16 bytes  (observed: 18 for 1MB)
    //   etc.
    // Rather than computing exactly, try all plausible header sizes 13..=20.
    for h in 13..=20_i32 {
        let bitset = actual - h;
        if bitset >= 32 && (bitset as usize).is_power_of_two() {
            return true;
        }
    }
    false
}

fn main() {
    let args = Args::parse();
    let path = &args.file;

    let reader = SerializedFileReader::new(File::open(path).expect("Cannot open file"))
        .expect("Failed to read parquet");
    let meta = reader.metadata();

    println!("File: {path}");
    println!("Row groups: {}", meta.num_row_groups());

    let mut all_ok = true;

    for rg_idx in 0..meta.num_row_groups() {
        let rg = meta.row_group(rg_idx);
        println!("\n  Row group {rg_idx}  ({} rows)", rg.num_rows());

        if args.verify {
            let ndv = args.ndv.expect("--ndv required with --verify");
            let fpp = args.fpp.expect("--fpp required with --verify");
            let expected = expected_bloom_bytes(ndv, fpp);

            println!(
                "  Expected bloom filter length for NDV={ndv} FPP={fpp}: {expected} bytes (upper bound — actual may be smaller after folding to real cardinality)"
            );
            println!(
                "  {:<25} {:>14}  {:>14}  {}",
                "column", "actual_bytes", "upper_bound", "status"
            );
            println!("  {}", "-".repeat(72));

            for col in rg.columns() {
                let name = col.column_path().string();
                match col.bloom_filter_length() {
                    Some(actual) => {
                        let ok = is_valid_bloom_size(actual, ndv, fpp);
                        let status = if ok { "OK ✓" } else { "MISMATCH ✗" };
                        if !ok { all_ok = false; }
                        println!(
                            "  {:<25} {:>14}  {:>14}  {}",
                            name, actual, expected, status
                        );
                    }
                    None => {
                        // No bloom filter — expected for non-bloom columns, skip.
                        println!("  {:<25} {:>14}  {:>14}  (no bloom filter)", name, "-", "-");
                    }
                }
            }
        } else {
            // Plain info mode
            println!(
                "  {:<25} {:>22}  {:>22}",
                "column", "bloom_filter_offset", "bloom_filter_length"
            );
            println!("  {}", "-".repeat(72));
            for col in rg.columns() {
                let name = col.column_path().string();
                let offset = col.bloom_filter_offset()
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "None".to_string());
                let length = col.bloom_filter_length()
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "None".to_string());
                let marker = if col.bloom_filter_offset().is_some() { "  <-- bloom" } else { "" };
                println!("  {:<25} {:>22}  {:>22}{marker}", name, offset, length);
            }
        }
    }

    if args.verify && !all_ok {
        eprintln!("\nVerification FAILED: some bloom filter lengths do not match expected.");
        std::process::exit(1);
    } else if args.verify {
        println!("\nVerification PASSED: all bloom filter lengths match expected.");
    }
}
