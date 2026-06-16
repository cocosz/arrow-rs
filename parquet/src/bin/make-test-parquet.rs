// Small test-data generator: writes a Parquet file that mimics the
// ClickBench bloom-filter layout — bloom filters on a subset of columns only.
//
// Build & run:
//   cargo build --features=arrow,cli --bin make-test-parquet
//   ./target/debug/make-test-parquet test_input.parquet

use std::fs::File;
use std::sync::Arc;

use arrow_array::{Int64Array, StringArray, RecordBatch};
use arrow_schema::{DataType, Field, Schema};
use parquet::arrow::ArrowWriter;
use parquet::file::properties::WriterProperties;
use parquet::schema::types::ColumnPath;

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "test_input.parquet".to_string());

    // Schema: 5 columns — bloom filters on WatchID, UserID, SearchPhrase only
    let schema = Arc::new(Schema::new(vec![
        Field::new("WatchID",      DataType::Int64,  false),
        Field::new("UserID",       DataType::Int64,  false),
        Field::new("SearchPhrase", DataType::Utf8,   true),
        Field::new("EventDate",    DataType::Int32,  false),  // NO bloom filter
        Field::new("CounterID",    DataType::Int32,  false),  // NO bloom filter
    ]));

    let props = WriterProperties::builder()
        // Global default: bloom filters OFF
        .set_bloom_filter_enabled(false)
        // Per-column overrides: bloom filters ON with specific NDV/FPP
        .set_column_bloom_filter_enabled(ColumnPath::from("WatchID"),      true)
        .set_column_bloom_filter_ndv(    ColumnPath::from("WatchID"),      500_000)
        .set_column_bloom_filter_fpp(    ColumnPath::from("WatchID"),      0.05)
        .set_column_bloom_filter_enabled(ColumnPath::from("UserID"),       true)
        .set_column_bloom_filter_ndv(    ColumnPath::from("UserID"),       500_000)
        .set_column_bloom_filter_fpp(    ColumnPath::from("UserID"),       0.05)
        .set_column_bloom_filter_enabled(ColumnPath::from("SearchPhrase"), true)
        .set_column_bloom_filter_ndv(    ColumnPath::from("SearchPhrase"), 500_000)
        .set_column_bloom_filter_fpp(    ColumnPath::from("SearchPhrase"), 0.05)
        .build();

    // 600_000 rows — above the NDV=500k threshold so bloom filter sizes are
    // actually driven by NDV/FPP rather than the minimum block size.
    let n: usize = 600_000;
    let watch_ids:   Vec<i64>   = (0..n as i64).collect();
    let user_ids:    Vec<i64>   = (0..n as i64).map(|i| i * 7 + 3).collect();
    let phrases:     Vec<&str>  = (0..n).map(|i| if i % 3 == 0 { "rust" } else if i % 3 == 1 { "parquet" } else { "bloom" }).collect();
    let event_dates: Vec<i32>   = (0..n as i32).map(|i| 20240101 + i % 365).collect();
    let counter_ids: Vec<i32>   = (0..n as i32).map(|i| i % 1000).collect();

    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(Int64Array::from(watch_ids)),
            Arc::new(Int64Array::from(user_ids)),
            Arc::new(StringArray::from(phrases)),
            Arc::new(arrow_array::Int32Array::from(event_dates)),
            Arc::new(arrow_array::Int32Array::from(counter_ids)),
        ],
    ).expect("Failed to create RecordBatch");

    let file = File::create(&path).expect("Unable to create output file");
    let mut writer = ArrowWriter::try_new(file, schema, Some(props))
        .expect("Failed to create ArrowWriter");
    writer.write(&batch).expect("Failed to write batch");
    writer.close().expect("Failed to close writer");

    println!("Written: {path}  ({n} rows)");
    println!("Bloom-filter columns: WatchID, UserID, SearchPhrase");
    println!("No bloom filter:      EventDate, CounterID");
}
