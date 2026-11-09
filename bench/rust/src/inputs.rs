//! The fixed messages of bench/inputs.zig, built as bench/go/inputs.go builds them: every value
//! follows from its index, so Zig, Go and Rust encode the same message.

use crate::protos::bench::v1::__buffa::oneof::medium::Contact;
use crate::protos::bench::v1::{
    Address, Deep, Large, Medium, Packed, Record, Small, Status, Strings, Tree, Varints,
};

const MEDIUM_SAMPLES_COUNT: i64 = 64;
const MEDIUM_TAGS_COUNT: usize = 16;
const MEDIUM_COUNTERS_COUNT: i64 = 16;
const MEDIUM_PREVIOUS_COUNT: u32 = 4;
const SAMPLE_SCALE: i64 = 1009;
const SAMPLE_OFFSET: i64 = 50_000;
const COUNTER_SCALE: i64 = 1_000_003;
const PREVIOUS_POSTAL_CODE_FIRST: u32 = 10_000;
const LARGE_RECORDS_COUNT: usize = 1000;
const RECORD_PAYLOAD_LEN: usize = 128;
const RECORD_VALUES_COUNT: usize = 8;
const RECORD_ID_FIRST: u64 = 1_000_000;
const PAYLOAD_RECORD_STEP: usize = 31;
const PAYLOAD_BYTE_STEP: usize = 7;
const VALUE_RECORD_STEP: usize = 13;
const VALUE_INDEX_STEP: usize = 17;
const VALUE_MODULUS: usize = 2001;
const VALUE_OFFSET: i32 = 1000;
const WEIGHT_STEP: f64 = 0.5;
const STATUS_COUNT: i32 = 4;
const DEEP_LEVELS_COUNT: i32 = 50;
const TREE_FANOUT: usize = 4;
pub const TREE_LEVELS_COUNT: usize = 4;
const PACKED_COUNT: i32 = 64;
const REAL_STEP: f64 = 0.25;
/// The text every ASCII string of `strings` is a prefix of, as in bench/inputs.zig.
const ASCII_TEXT: &str = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-_";
/// The phrase the large message's description repeats, as bench/inputs.zig repeats it.
const DESCRIPTION_PHRASE: &str = "A batch of records: données, 日本語のテキスト, ünïcode — end. ";
const DESCRIPTION_REPEATS: usize = 100;

pub fn small() -> Small {
    Small {
        id: 12_345,
        created: 1_700_000_000_123,
        active: true,
        name: "alice@example.com".into(),
        score: 98.625,
        ..Default::default()
    }
}

fn address(street: &str, city: &str, postal_code: u32) -> Address {
    Address {
        street: street.into(),
        city: city.into(),
        country: "US".into(),
        postal_code,
        ..Default::default()
    }
}

pub fn medium() -> Medium {
    let office = address("500 Terry Francine Street", "San Francisco", 94_158);
    Medium {
        id: 9_876_543_210,
        name: "Medium benchmark record".into(),
        status: Status::STATUS_ACTIVE.into(),
        home: address("1600 Amphitheatre Parkway", "Mountain View", 94_043).into(),
        samples: (0..MEDIUM_SAMPLES_COUNT)
            .map(|i| i * i * SAMPLE_SCALE - SAMPLE_OFFSET)
            .collect(),
        tags: (0..MEDIUM_TAGS_COUNT)
            .map(|i| format!("tag-{i:02}"))
            .collect(),
        counters: (0..MEDIUM_COUNTERS_COUNT)
            .map(|i| (format!("counter-{i:02}"), (i + 1) * COUNTER_SCALE))
            .collect(),
        previous: (0..MEDIUM_PREVIOUS_COUNT)
            .map(|i| {
                address(
                    &format!("{i:02} Main Street"),
                    "Springfield",
                    PREVIOUS_POSTAL_CODE_FIRST + i,
                )
            })
            .collect(),
        checksum: 0xdead_beef_cafe_f00d,
        ratio: 0.75,
        delta: -12_345,
        contact: Some(Contact::Office(Box::new(office))),
        ..Default::default()
    }
}

pub fn large() -> Large {
    let records = (0..LARGE_RECORDS_COUNT)
        .map(|i| Record {
            id: RECORD_ID_FIRST + i as u64,
            key: format!("record-{i:05}"),
            // The byte keeps the low eight bits, as Go's byte() conversion does.
            payload: (0..RECORD_PAYLOAD_LEN)
                .map(|j| (i * PAYLOAD_RECORD_STEP + j * PAYLOAD_BYTE_STEP) as u8)
                .collect(),
            values: (0..RECORD_VALUES_COUNT)
                .map(|j| {
                    ((i * VALUE_RECORD_STEP + j * VALUE_INDEX_STEP) % VALUE_MODULUS) as i32
                        - VALUE_OFFSET
                })
                .collect(),
            weight: i as f64 * WEIGHT_STEP,
            status: buffa::EnumValue::from(i as i32 % STATUS_COUNT),
            ..Default::default()
        })
        .collect();
    Large {
        name: "Large benchmark batch".into(),
        records,
        description: DESCRIPTION_PHRASE.repeat(DESCRIPTION_REPEATS),
        ..Default::default()
    }
}

pub fn deep() -> Deep {
    let mut child: Option<Deep> = None;
    for i in (0..DEEP_LEVELS_COUNT).rev() {
        child = Some(Deep {
            level: i + 1,
            label: format!("level-{i:02}"),
            child: child.into(),
            ..Default::default()
        });
    }
    child.unwrap_or_default()
}

/// Every varint kind at each length from 1 to 10 bytes, as bench/inputs.zig.
pub fn varints() -> Varints {
    Varints {
        int32_one: 100,
        int32_two: 300,
        int32_negative: -1,
        int64_three: 100_000,
        int64_eight: 1 << 50,
        uint32_four: 1 << 22,
        uint32_five: 4_000_000_000,
        uint64_six: 1 << 36,
        uint64_ten: u64::MAX,
        sint32_one: -5,
        sint32_three: -50_000,
        sint64_seven: -(1 << 44),
        sint64_nine: 1 << 60,
        flag: true,
        status: Status::STATUS_CLOSED.into(),
        uint64_two: 200,
        ..Default::default()
    }
}

pub fn strings() -> Strings {
    let prefix = |len: usize| ASCII_TEXT[..len].to_string();
    Strings {
        one: prefix(1),
        three: prefix(3),
        seven: prefix(7),
        eight: prefix(8),
        fifteen: prefix(15),
        sixteen: prefix(16),
        thirty_one: prefix(31),
        thirty_two: prefix(32),
        sixty_four: prefix(64),
        latin: "données, ünïcode".into(),
        cjk: "日本語のテキスト".into(),
        ..Default::default()
    }
}

/// A node with `TREE_FANOUT` children on each level, `levels` levels deep.
pub fn tree(levels: usize) -> Tree {
    let children = if levels == 0 {
        Vec::new()
    } else {
        (0..TREE_FANOUT).map(|_| tree(levels - 1)).collect()
    };
    Tree {
        children,
        ..Default::default()
    }
}

pub fn packed() -> Packed {
    Packed {
        small: (0..PACKED_COUNT).collect(),
        wide: (0..PACKED_COUNT).map(|i| 1u64 << i).collect(),
        zigzag: (0..PACKED_COUNT).map(|i| i - PACKED_COUNT / 2).collect(),
        reals: (0..PACKED_COUNT)
            .map(|i| f64::from(i) * REAL_STEP)
            .collect(),
        ..Default::default()
    }
}
