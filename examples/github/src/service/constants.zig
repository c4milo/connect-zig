//! The GitHub-style service's limits (decision 42).

/// The calls an anonymous caller makes, and the calls each user makes, before the rate limit.
pub const limit_anonymous = 10;
pub const limit_user = 100;
/// The branches the compiler may take to write the decimal text of each count up to `limit_user`.
pub const decimals_branch_quota = 100_000;

/// The largest page a list answers, and the page a request with no size gets.
pub const page_size_max = 20;
pub const page_size_default = 10;
/// The base of a page token's digits: a token is the decimal offset of the page's first item.
pub const page_token_base = 10;

/// The longest repository name (GitHub's own limit).
pub const name_len_max = 100;
/// Room for a page token, a resource's name in a detail, and an encoded detail.
pub const token_len = 20;
pub const resource_name_len = 256;
pub const detail_len = 512;

/// The longest message a route reads or writes, a page of issues in JSON among them, and the
/// longest JSON token.
pub const message_bytes = 8192;
pub const token_bytes = 4096;

/// The paths of an update mask, at most: one for each field it may name.
pub const mask_paths_max = 4;

/// The most repositories, issues and events the store holds, and the octets of their text.
pub const repositories_max = 16;
pub const issues_max = 64;
pub const events_max = 128;
pub const text_len = 16 * 1024;
/// The most topics of a repository, and labels of an issue.
pub const topics_max = 4;
pub const labels_max = 4;
/// The instant the store's clock starts at: 2027-01-15T08:00:00Z. Its first change takes the
/// second after.
pub const epoch_seconds: i64 = 1_800_000_000;
/// GitHub's ids of the users octocat and hubot.
pub const octocat_id = 583231;
pub const hubot_id = 480938;
