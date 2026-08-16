# Profile Analyzer

Tracks followers and following over time: scan → store snapshot → diff against the previous
snapshot → present seven derived lists. Lives in `Source/ProfileAnalyzer/` (six files, ~3.7k lines,
compiled as separate TUs), reached from Theta settings → General → *Profile Analyzer*, which is a
`view`-type row pushing `THProfileAnalyzerViewController`.

```
THProfileAnalyzerViewController          UI, session/networker discovery, orchestration
  └── THProfileAnalyzerNetworkDelegate   implements the API client's transport
        └── THProfileAnalyzerAPIClient   URL construction only
              └── THProfileAnalyzerService   pagination, pacing, backoff, guards
                    └── THProfileAnalyzerTypes  User / Snapshot / DiffResult / Result
THProfileAnalyzerStorage                 raw sqlite3, one DB per account
THProfileAnalyzerDiffEngine              pure set math
```

## 1. Requests ride Instagram's own networker

The analyzer does not authenticate by itself. `THProfileAnalyzerAPIClient` only builds URLs under
`https://i.instagram.com/api/v1/` and delegates transport to
`THProfileAnalyzerNetworkDelegate -performGETRequestWithURL:success:failure:`
(`THProfileAnalyzerViewController.m:1172`), which:

1. Walks the app to find IG's networker — `UIApplication.delegate._appCoordinator._sessionManager
   ._activeUserSessions.presentedUserSession.userActions.networker`, with a fallback path through
   any `IGWindow`'s `_userSession.userActions.networker`
   (`THProfileAnalyzerGetNetworker`, `:48`). Every hop tries the ivar directly (`THGetIvar`) and
   then KVC.
2. Builds a signed IG request (`IGAPIRequestBuilder` first, then `IGURLRequest` with the full URL)
   and calls `-startAPIRequest:policy:successHandler:failureHandler:`, or the 3-argument variant.
   Method code `0` is used for GET — the in-tree comment notes that sending `1` produced HTTP 405.
3. Normalizes the callback. IG calls back with `(NSHTTPURLResponse, parsedBody)`; the delegate
   picks whichever argument is dictionary-like, and if the body is a custom dictionary-like object
   it deep-copies it into a real `NSDictionary`, normalizing `users` entries
   (`pk`/`PK`, `full_name`/`fullName`, `profile_pic_url`/`profilePicUrl`, `profile_pic_id`) and
   `next_max_id`/`nextMaxId`/`NextMaxId`.
4. Falls back to a hand-rolled `NSURLSession` request with a spoofed Instagram `User-Agent`,
   `X-IG-App-ID`, and cookies from `NSHTTPCookieStorage` if no networker was found. The in-tree
   comment is blunt about this: it "often 401"s. Error messages are lifted from the JSON
   (`message`, `feedback_message`, `error_message`) so throttle text reaches the UI.

The current account's primary key comes from `+currentUserPKFromInstagram` (`:1405`): scan
`UIApplication.windows` for an `IGWindow`, then `userSession.user.pk` (accepting `NSNumber` or
`NSString`, with a `-pk` selector fallback). No PK → the service fails with
`THProfileAnalyzerServiceErrorNoSession`.

Endpoints used:

| Endpoint | Purpose |
| --- | --- |
| `users/<pk>/info/` | follower/following/media counts + header info |
| `friendships/<pk>/followers/` (`?max_id=`) | paginated followers |
| `friendships/<pk>/following/` (`?max_id=`) | paginated following |

## 2. Pacing and backoff

`Source/ProfileAnalyzer/THProfileAnalyzerService.m` is written entirely around not tripping
Instagram's rate limiter. Constants at the top of the file:

| Constant | Value | Meaning |
| --- | --- | --- |
| `THProfileAnalyzerMaxAnalyzableFollowers` | 13000 | hard refusal above this follower count |
| `TH_PA_PAGE_DELAY_S` | 1.05 s | base gap between pagination requests |
| `TH_PA_AFTER_PROFILE_INFO_DELAY_S` | 0.55 s | pause between `users/info/` and the first page |
| `TH_PA_MAX_PAGE_FAILURE_RETRIES` | 6 | retries per failing request |

- `THPAPageDelayWithJitter()` adds ±0.15 s of jitter (floor 0.72 s) so pagination isn't perfectly
  periodic.
- `THPABackoffSecondsForAttempt()` steps through **5, 10, 20, 40, 80, 90 seconds**, retrying the
  *same* cursor so no page is skipped.
- `THPAErrorIndicatesIGThrottle()` treats HTTP 429 and 503 as throttling **and also 400**, because
  Instagram signals action/rate spam with 400 plus a "limit how often…" body; it additionally
  sniffs the localized description for `rate`, `limit`, `too many`, `slow`, `try again`.
- `THPAShouldAvoidRetryHTTPCode()` refuses to retry 401/402/404/405 — permanent client errors.
- Exhausting retries converts the error to `THProfileAnalyzerServiceErrorRateLimited` with a
  user-facing "Instagram is limiting these requests. Wait a while, then try again."

Progress is reported as a fraction weighted by the *expected* follower and following counts from
`users/info/`, so the bar advances proportionally through the two stages rather than jumping
50 % at the boundary. Cancellation is cooperative: `-cancel` sets a flag that every callback and
timer checks, and the run finishes with `THProfileAnalyzerServiceErrorCancelled`.

Only one run at a time: `runForSelfWithHeaderInfo:progress:completion:` returns a `Cancelled`
error if `isRunning`.

## 3. Storage

`Source/ProfileAnalyzer/THProfileAnalyzerStorage.m` uses `sqlite3` directly (linked with
`-lsqlite3` in the Makefile). One database per account:

```
<Application Support>/ProfileAnalyzer/<userPK>/Stats.sqlite
```

Schema (created lazily with `CREATE TABLE IF NOT EXISTS`):

```sql
CREATE TABLE scans (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  user_pk             TEXT    NOT NULL,
  scanned_at          REAL    NOT NULL,   -- NSDate timeIntervalSince1970
  followers_json      TEXT    NOT NULL,   -- JSON array of user dictionaries
  following_json      TEXT    NOT NULL,
  api_followers_count INTEGER DEFAULT -1, -- authoritative counts from users/info/
  api_following_count INTEGER DEFAULT -1
);
```

`addAPICountColumnsIfNeeded()` (`:11`) does a small migration: `PRAGMA table_info(scans)` and
`ALTER TABLE … ADD COLUMN` for the two count columns, so databases written by older builds keep
working. Everything else is plain prepared statements:

| Method | SQL shape |
| --- | --- |
| `saveSnapshot:error:` | `INSERT INTO scans …` |
| `loadMostRecentSnapshotForUserPK:error:` | `… ORDER BY id DESC LIMIT 1` |
| `loadSnapshotAtIndex:forUserPK:error:` | `… ORDER BY id DESC LIMIT 1 OFFSET <n>` (0 = newest) |
| `snapshotCountForUserPK:error:` | `SELECT COUNT(*)` |
| `deleteSnapshotAtNewestFirstIndex:forUserPK:error:` | select the id at that offset, then `DELETE … WHERE id = ?` |
| `deleteAllSnapshotsForUserPK:error:` | `DELETE … WHERE user_pk = ?` |
| `updateAPICountsForMostRecentScanWithUserPK:…` | `UPDATE … WHERE id = (SELECT MAX(id) …)` |

Follower/following arrays are stored as JSON text, so a snapshot is one row — simple, and cheap to
diff in memory. Nothing leaves the device.

## 4. Diffing

`THProfileAnalyzerDiffEngine` is pure set math over `THProfileAnalyzerUser` (equality/hash by
`pk`), producing seven lists:

| Field | Definition |
| --- | --- |
| `mutualFollowers` | current followers ∩ current following |
| `notFollowingMeBack` | current following − current followers |
| `youDontFollowBack` | current followers − current following |
| `followersGained` | current followers − previous followers |
| `followersLost` | previous followers − current followers |
| `followingAdded` | current following − previous following |
| `followingRemoved` | previous following − current following |

With no previous snapshot the four delta lists are empty and only the three "current state" lists
are meaningful. `THPANEnrichWithByPK()` replaces each entry with the richest copy of that user
found in the snapshot (`usersByPKFromSnapshot` merges both lists), so display names and profile
pictures are populated even for users that only appeared in one list.

## 5. UI

`THProfileAnalyzerViewController.m` (2222 lines) hosts several view controllers in one file:

| Class | Role |
| --- | --- |
| `THProfileAnalyzerViewController` | header (avatar, counts), scan button with live progress, the seven metric rows (`THProfileAnalyzerMetric` enum) |
| `THProfileAnalyzerListViewController` | one metric's user list, searchable (`UISearchResultsUpdating`), rows tappable to a per-user history |
| `THProfileAnalyzerScanHistoryViewController` | stored scans: clear all, swipe-to-delete one, or Compare mode to select and delete several |
| `THProfileAnalyzerScanCompareViewController` + `…GraphView` | compares selected scans, with a hand-drawn graph |
| `THProfileAnalyzerUserHistoryViewController` | for one user across snapshots: whether they followed you at each scan (`_userPKInArray`) |
| `THProfileAnalyzerNetworkDelegate` | the transport described in §1 |

`+prefetchProfileImageIfNeeded` is called from `THTweak.m` at load, on
`UIApplicationDidBecomeActive`, and again after 2 s, so the analyzer's header avatar is warm before
the user opens it; it resolves `HDProfilePicURL`/`hdProfilePicURL`/`profilePicURL` by name.

## 6. Operational notes

- Above 13 000 followers the service refuses outright. The settings `info` text warns that very
  large lists (13 000+ total) may still be limited by Instagram.
- A scan of a large account is minutes long by construction: ~1 s per page of followers *and*
  following, plus up to 90 s per backed-off retry.
- If IG renames any hop in the networker chain, requests fall through to the cookie-based path,
  which typically 401s — so "Profile Analyzer stopped working after an update" usually means the
  session-walk needs fixing, not the endpoints.
