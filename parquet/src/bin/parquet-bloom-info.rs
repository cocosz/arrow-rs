// Prints per-column bloom_filter_offset for every row group.
// A non-None offset means that column has a bloom filter in the file.
//
// Build: cargo build --features=arrow,cli --bin parquet-bloom-info
// Run:   ./target/debug/parquet-bloom-info <file.parquet>

use std::fs::File;
use parquet::file::{reader::FileReader, serialized_reader::SerializedFileReader};

fn main() {
    let path = std::env::args().nth(1).expect("Usage: parquet-bloom-info <file.parquet>");
    let reader = SerializedFileReader::new(File::open(&path).expect("open"))
        .expect("parquet open");
    let meta = reader.metadata();

    println!("File: {path}");
    println!("Row groups: {}", meta.num_row_groups());

    for rg_idx in 0..meta.num_row_groups() {
        let rg = meta.row_group(rg_idx);
        println!("\n  Row group {rg_idx}  ({} rows)", rg.num_rows());
        println!("  {:<25} {:>22}  {:>22}", "column", "bloom_filter_offset", "bloom_filter_length");
        println!("  {}", "-".repeat(72));
        for col in rg.columns() {
            let name   = col.column_path().string();
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
