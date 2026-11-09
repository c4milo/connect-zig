//! Reads every field of a message and folds what it read into one number, as bench/walk.zig and
//! bench/go/walk.go do: each integer and enum as a sign-extended 64-bit value, each bool as 0 or
//! 1, each float's bits, and each string's and bytes field's length, added with wrapping. A tree,
//! which holds no scalar, adds one for each node.
//!
//! Each message has two walks with one body: one over the owned message, which JSON decodes to,
//! and one over the zero-copy view, which binary decodes to. The field names are the same.

use crate::protos::bench::v1::__buffa::oneof::medium::Contact;
use crate::protos::bench::v1::__buffa::view::oneof::medium::Contact as ContactView;
use crate::protos::bench::v1::{
    Address, AddressView, Deep, DeepView, Large, LargeView, Medium, MediumView, Packed, PackedView,
    Record, RecordView, Small, SmallView, Strings, StringsView, Tree, TreeView, Varints,
    VarintsView,
};

/// A message, or a view of one, that the benchmark reads whole.
pub trait Walk {
    fn walk(&self) -> u64;
}

fn signed(value: impl Into<i64>) -> u64 {
    value.into() as u64
}

fn length(text: impl AsRef<[u8]>) -> u64 {
    text.as_ref().len() as u64
}

fn fold(values: impl IntoIterator<Item = u64>) -> u64 {
    values.into_iter().fold(0u64, u64::wrapping_add)
}

/// Implements `Walk` for the owned message and its view, with one body that reads `$m`.
macro_rules! walks {
    ($owned:ty, $view:ty, |$m:ident| $body:expr) => {
        impl Walk for $owned {
            fn walk(&self) -> u64 {
                let $m = self;
                $body
            }
        }
        impl Walk for $view {
            fn walk(&self) -> u64 {
                let $m = self;
                $body
            }
        }
    };
}

walks!(Small, SmallView<'_>, |m| fold([
    signed(m.id),
    signed(m.created),
    u64::from(m.active),
    length(&m.name),
    m.score.to_bits(),
]));

walks!(Address, AddressView<'_>, |m| fold([
    length(&m.street),
    length(&m.city),
    length(&m.country),
    u64::from(m.postal_code),
]));

walks!(Medium, MediumView<'_>, |m| fold([
    m.id,
    length(&m.name),
    signed(m.status.to_i32()),
    m.home.as_option().map_or(0, Walk::walk),
    fold(m.samples.iter().map(|&sample| signed(sample))),
    fold(m.tags.iter().map(length)),
    // Addition does not depend on order, so the map is read in its own order.
    fold(
        m.counters
            .iter()
            .map(|(key, value)| length(key).wrapping_add(signed(*value)))
    ),
    m.contact.as_ref().map_or(0, Walk::walk),
    fold(m.previous.iter().map(Walk::walk)),
    m.checksum,
    u64::from(m.ratio.to_bits()),
    signed(m.delta),
]));

walks!(Contact, ContactView<'_>, |m| match m {
    Self::Email(email) => length(email),
    Self::Phone(phone) => length(phone),
    Self::Office(office) => office.walk(),
});

walks!(Record, RecordView<'_>, |m| fold([
    m.id,
    length(&m.key),
    length(&m.payload),
    fold(m.values.iter().map(|&value| signed(value))),
    m.weight.to_bits(),
    signed(m.status.to_i32()),
]));

walks!(Large, LargeView<'_>, |m| fold([
    length(&m.name),
    length(&m.description),
    fold(m.records.iter().map(Walk::walk)),
]));

walks!(Deep, DeepView<'_>, |m| {
    let mut total = 0u64;
    let mut node = Some(m);
    while let Some(current) = node {
        total = fold([total, signed(current.level), length(&current.label)]);
        node = current.child.as_option();
    }
    total
});

walks!(Varints, VarintsView<'_>, |m| fold([
    signed(m.int32_one),
    signed(m.int32_two),
    signed(m.int32_negative),
    signed(m.int64_three),
    signed(m.int64_eight),
    u64::from(m.uint32_four),
    u64::from(m.uint32_five),
    m.uint64_six,
    m.uint64_ten,
    signed(m.sint32_one),
    signed(m.sint32_three),
    signed(m.sint64_seven),
    signed(m.sint64_nine),
    u64::from(m.flag),
    signed(m.status.to_i32()),
    m.uint64_two,
]));

walks!(Strings, StringsView<'_>, |m| fold([
    length(&m.one),
    length(&m.three),
    length(&m.seven),
    length(&m.eight),
    length(&m.fifteen),
    length(&m.sixteen),
    length(&m.thirty_one),
    length(&m.thirty_two),
    length(&m.sixty_four),
    length(&m.latin),
    length(&m.cjk),
]));

walks!(Tree, TreeView<'_>, |m| 1u64
    .wrapping_add(fold(m.children.iter().map(Walk::walk))));

walks!(Packed, PackedView<'_>, |m| fold([
    fold(m.small.iter().map(|&value| signed(value))),
    fold(m.wide.iter().copied()),
    fold(m.zigzag.iter().map(|&value| signed(value))),
    fold(m.reals.iter().map(|value| value.to_bits())),
]));
