// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

//! Rewrites a Parquet file with new Bloom filter NDV/FPP settings, preserving
//! *exactly* the set of columns that had Bloom filters in the source file.
//!
//! Unlike `parquet-rewrite --bloom-filter-enabled true`, this tool does NOT
//! enable Bloom filters on columns that didn't have them originally.
//!
//! # Install / build
//!
//! ```
//! cargo build --features=arrow,cli --bin parquet-rewrite-bloom
//! ```
//!
//! # Usage
//!
//! ```
//! parquet-rewrite-bloom \
//!     --input  hits.parquet \
//!     --output hits_ndv1m.parquet \
//!     --bloom-filter-ndv 1000000 \
//!     --bloom-filter-fpp 0.01
//! ```
//!
//! Omitting `--bloom-filter-ndv` or `--bloom-filter-fpp` keeps the parquet
//! writer's default for that parameter (NDV = 1 000 000, FPP = 0.05).
//!
//! Pass `--dry-run` to print the discovered bloom-filter columns and exit
//! without writing any output file.

use std::collections::HashSet;
use std::fs::File;

use arrow_array::RecordBatchReader;
use clap::Parser;
use parquet::{
    arrow::{ArrowWriter, arrow_reader::ParquetRecordBatchReaderBuilder},
    file::{
        properties::{WriterProperties, WriterPropertiesBuilder},
        reader::FileReader,
        serialized_reader::SerializedFileReader,
    },
    schema::types::ColumnPath,
};

#[derive(Debug, Parser)]
#[clap(
    author,
    version,
    about(
        "Rewrite a Parquet file changing Bloom filter NDV/FPP \
         while keeping the same set of bloom-filter-enabled columns"
    ),
    long_about = None
)]
struct Args {
    /// Path to the input Parquet file.
    #[clap(short, long)]
    input: String,

    /// Path for the output Parquet file.
    #[clap(short, long)]
    output: Option<String>,

    /// New number-of-distinct-values hint for the Bloom filter.
    /// Omit to use the writer default (1 000 000).
    #[clap(long)]
    bloom_filter_ndv: Option<u64>,

    /// New false-positive probability for the Bloom filter (0 < fpp < 1).
    /// Omit to use the writer default (0.05).
    #[clap(long)]
    bloom_filter_fpp: Option<f64>,

    /// Print the bloom-filter columns found in the source file and exit
    /// without writing anything.
    #[clap(long, default_value_t = false)]
    dry_run: bool,
}

fn main() {
    let args = Args::parse();

    // ------------------------------------------------------------------ //
    // 1. Discover which columns have Bloom filters in the source file.    //
    //                                                                      //
    //    A column has a Bloom filter if *any* row-group chunk for that     //
    //    column has a non-None bloom_filter_offset() in its metadata.      //
    // ------------------------------------------------------------------ //
    let meta_reader =
        SerializedFileReader::new(File::open(&args.input).expect("Unable to open input file"))
            .expect("Failed to create Parquet reader");

    let metadata = meta_reader.metadata();

    // Collect key-value metadata to carry over to the output file.
    let kv_md = metadata
        .file_metadata()
        .key_value_metadata()
        .cloned();

    let mut bloom_columns: HashSet<String> = HashSet::new();

    for rg in metadata.row_groups() {
        for col in rg.columns() {
            if col.bloom_filter_offset().is_some() {
                bloom_columns.insert(col.column_path().string());
            }
        }
    }

    // ------------------------------------------------------------------ //
    // 2. Report and optionally exit (--dry-run).                          //
    // ------------------------------------------------------------------ //
    if bloom_columns.is_empty() {
        println!("No Bloom filters found in source file — nothing to rewrite.");
        return;
    }

    let mut sorted: Vec<&String> = bloom_columns.iter().collect();
    sorted.sort();

    println!(
        "Bloom-filter columns in source ({} total):",
        bloom_columns.len()
    );
    for col in &sorted {
        println!("  {col}");
    }

    if args.dry_run {
        println!("\n--dry-run: exiting without writing output.");
        return;
    }

    let output_path = args
        .output
        .as_deref()
        .expect("--output is required unless --dry-run is set");

    // ------------------------------------------------------------------ //
    // 3. Build WriterProperties:                                           //
    //    • table default  → Bloom filter OFF                               //
    //    • per-column     → Bloom filter ON + new NDV/FPP                  //
    // ------------------------------------------------------------------ //
    let mut props: WriterPropertiesBuilder = WriterProperties::builder()
        .set_key_value_metadata(kv_md)
        // Disable bloom filters globally so non-bloom columns are unaffected.
        .set_bloom_filter_enabled(false);

    for col_name in &bloom_columns {
        let col_path = ColumnPath::from(col_name.as_str());

        props = props.set_column_bloom_filter_enabled(col_path.clone(), true);

        if let Some(ndv) = args.bloom_filter_ndv {
            props = props.set_column_bloom_filter_ndv(col_path.clone(), ndv);
        }
        if let Some(fpp) = args.bloom_filter_fpp {
            props = props.set_column_bloom_filter_fpp(col_path.clone(), fpp);
        }
    }

    let writer_properties = props.build();

    // ------------------------------------------------------------------ //
    // 4. Stream record batches from source → output.                      //
    // ------------------------------------------------------------------ //
    let batch_reader = ParquetRecordBatchReaderBuilder::try_new(
        File::open(&args.input).expect("Unable to open input file"),
    )
    .expect("Failed to build record batch reader")
    .build()
    .expect("Failed to open record batch reader");

    let schema = batch_reader.schema();

    let mut writer = ArrowWriter::try_new(
        File::create(output_path).expect("Unable to create output file"),
        schema,
        Some(writer_properties),
    )
    .expect("Failed to create ArrowWriter");

    let mut rows_written: usize = 0;
    for maybe_batch in batch_reader {
        let batch = maybe_batch.expect("Error reading record batch");
        rows_written += batch.num_rows();
        writer.write(&batch).expect("Error writing record batch");
    }

    writer.close().expect("Failed to finalise output file");

    println!(
        "\nWrote {rows_written} rows → {output_path}"
    );
    println!("Bloom filter NDV : {}", args.bloom_filter_ndv.map_or("default".to_string(), |v| v.to_string()));
    println!("Bloom filter FPP : {}", args.bloom_filter_fpp.map_or("default".to_string(), |v| v.to_string()));
}
