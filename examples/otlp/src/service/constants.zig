//! The OTLP receiver's limits (decision 42).

/// The octets of the export requests the receiver keeps, at most. A request past them is refused,
/// and its spans are counted in the answer's `partial_success`. `Received` answers with all of
/// them, so a router's response memory holds them with room for the headers.
pub const kept_len_max = 32 * 1024;
/// The resource spans of one request, and the scope spans of each, that `Export` reads at most.
pub const resources_max = 64;
pub const scopes_max = 64;
