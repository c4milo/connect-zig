# A GitHub-style API

`github.v1.RepositoryService` and `github.v1.IssueService`, used as a real client would use an
API like GitHub's: bearer tokens, a rate limit, pages, field masks, private resources and
streams. The store is a fixed table in memory, so each run starts the same.

- `Auth` reads a bearer token; a change needs one, and a read takes one or none.
- `RateLimit` counts each caller's calls and sets GitHub's `x-ratelimit-*` headers. Anonymous
  callers have 10 calls in all, and each user has 100.
- Failures carry `NotFound`, `AlreadyExists`, `BadField` and `RateLimited` details. A private
  repository reads as not found to anyone but its owner.

## Files

| Path | Holds |
| --- | --- |
| [proto/github/v1/github.proto](proto/github/v1/github.proto) | The schema |
| [src/service/service.zig](src/service/service.zig) | `Auth`, `RateLimit` and the route table |
| [src/service/repositories.zig](src/service/repositories.zig), [src/service/issues.zig](src/service/issues.zig) | The handlers |
| [src/service/store.zig](src/service/store.zig), [src/service/room.zig](src/service/room.zig) | The fixed store, and the replies' room |
| [src/main.zig](src/main.zig) | The check: a whole session, over h2 and h3 |
| [src/serve.zig](src/serve.zig) | The same routes on a socket, to play with |

## Run it

```sh
zig build run
```

## Play with it

```sh
zig build serve
```

The tokens are `ghp_octocat_example`, for octocat, and `ghp_hubot_example`, for hubot. From this
folder, with `C='--cacert ../harness/tls/ca.pem'` and `U=https://127.0.0.1:8443`:

```sh
curl $C -H 'authorization: Bearer ghp_octocat_example' \
  --json '{"name":"hello-world","description":"My first repository","topics":["zig","rpc"]}' \
  $U/github.v1.RepositoryService/CreateRepository
curl $C --json '{"owner":"octocat","name":"hello-world"}' $U/github.v1.RepositoryService/GetRepository
curl $C --json '{"owner":"octocat"}' $U/github.v1.RepositoryService/ListRepositories
curl $C -H 'authorization: Bearer ghp_octocat_example' \
  --json '{"owner":"octocat","repository":"hello-world","title":"Add a README","labels":["docs"]}' \
  $U/github.v1.IssueService/CreateIssue
curl $C --json '{"owner":"octocat","repository":"hello-world","state":"ISSUE_STATE_OPEN"}' \
  $U/github.v1.IssueService/ListIssues
curl $C -H 'authorization: Bearer ghp_octocat_example' \
  --json '{"owner":"octocat","repository":"hello-world","number":1,"issue":{"state":"ISSUE_STATE_CLOSED"},"updateMask":"state"}' \
  $U/github.v1.IssueService/UpdateIssue
```

`ImportIssues` is a client stream and `WatchEvents` a server stream, so `buf curl` calls them:

```sh
buf curl --schema proto $C -H 'authorization: Bearer ghp_octocat_example' \
  --data '{"owner":"octocat","repository":"hello-world","title":"Crash on start"}{"owner":"octocat","repository":"hello-world","title":"Slow startup"}' \
  $U/github.v1.IssueService/ImportIssues
buf curl --schema proto $C --data '{"owner":"octocat","repository":"hello-world"}' \
  $U/github.v1.IssueService/WatchEvents
```

The store keeps its own clock, so its times start at 2027-01-15T08:00:01Z.
