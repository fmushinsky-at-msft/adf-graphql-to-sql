# Incremental GraphQL → Azure SQL sync with Azure Data Factory

A complete, working sample that incrementally syncs data from a REST service (which exposes its
data over **GraphQL**) into an **Azure SQL** database using **Azure Data Factory**, driven by a
**watermark**. The pipeline inserts new rows, updates changed rows and deletes rows that no longer
exist at the source. All authentication uses **system-assigned managed identities** — there are no
secrets anywhere in this repository.

---

## Architecture

```
┌────────────────────┐        SAMI         ┌─────────────────────┐
│  Source Azure SQL  │◄────────────────────│  App Service        │
│  demo.Restaurant   │  db_datareader      │  ASP.NET Core 10    │
│  (75 sample rows)  │                     │  HotChocolate       │
└────────────────────┘                     │  GraphQL, anonymous │
										   └──────────┬──────────┘
													  │  HTTPS POST /graphql
													  │  30 rows per page
													  ▼
										   ┌─────────────────────┐
										   │  Azure Data Factory │
										   │  PL_Sync_Restaurants│
										   │  _GraphQL_To_Sql    │
										   └──────────┬──────────┘
													  │  SAMI
													  │  db_datareader / db_datawriter
													  ▼
										   ┌─────────────────────┐
										   │ Destination Azure   │
										   │ SQL                 │
										   │  stg.Restaurant     │
										   │  stg.RestaurantKey  │
										   │  dbo.Restaurant     │
										   │  dbo.WatermarkCtrl  │
										   └─────────────────────┘
```

### How one pipeline run works

| # | Activity | What it does |
|---|----------|--------------|
| 1 | `LookupStoredWatermark` | Reads the watermark left by the last successful run — the **exclusive lower bound** of this run's delta window. |
| 2 | `GetSourceWatermark` | Asks the API for `MAX(LastUpdatedDateTime)` and the total row count, once. This **pins the upper bound** so offset paging stays stable even if rows change mid-run. |
| 3 | `CheckSourceWatermarkResponse` | GraphQL reports errors with HTTP 200, so a failed query looks like a successful web call. This fails the run with the actual error text instead of an opaque expression error. |
| 4 | `GetDeltaRowCount` | Asks how many rows fall inside the window, so the load can be verified afterwards. `CheckDeltaRowCountResponse` guards this response the same way as step 3. |
| 5 | `StartSync` | Truncates both staging tables so a run always starts clean, even after a previous failure. |
| 6 | `UntilAllDeltaPagesCopied` | Pages `restaurants(updatedAfter, updatedThrough, skip)` 30 rows at a time into `stg.Restaurant`. Stops when a page returns fewer than 30 rows. |
| 7 | `UntilAllKeyPagesCopied` | Pages `restaurantKeys(skip)` into `stg.RestaurantKey`. A watermark delta can never reveal a **deleted** row, so the full key set is reconciled separately. |
| 8 | `ApplySync` | One transaction: verify both staged sets against the counts from steps 2 and 4, `MERGE` the delta (insert new / update genuinely changed), delete targets whose key is absent from the staged key set, and advance the watermark. Returns run statistics. |

### Design decisions worth knowing

**Timestamps travel as strings.** `CreateDateTime` / `LastUpdatedDateTime` are exposed as GraphQL
`String`, formatted `yyyy-MM-ddTHH:mm:ss.fff` (UTC, no offset). This matches `datetime2(3)` exactly,
converts implicitly in T-SQL, sorts lexicographically, and sidesteps every datetime-scalar surprise
in the ADF ↔ GraphQL path.

**Paging is an `Until` loop, not the REST connector's pagination rules.** A Copy activity cannot
surface a cursor from a GraphQL POST body, so the pipeline drives `skip` itself. The loop exits when
`rowsCopied < pageSize`. (ADF variables cannot self-reference, hence the `DataSkip` / `DataSkipNext`
pairs.)

**The key scan is ordered by the primary key on purpose — this is a correctness choice, not a
stylistic one.** `restaurantKeys` sorts by `RestaurantId`; the delta scan sorts by
`(LastUpdatedDateTime, RestaurantId)`. It is tempting to drop `restaurantKeys` and harvest keys from
the general `restaurants` query instead, selecting only the id field — GraphQL makes that trivial,
and the payload is the same size (636 vs 630 bytes per page, measured). Doing so would inherit that
query's *mutable* sort key, and that is the problem: `OFFSET` paging assumes rows hold still. If a
row ahead of the cursor is updated mid-scan it jumps to the end of a timestamp ordering, every row
behind it shifts down one position, and the next `OFFSET` **skips a live row**. That key is then
missing from `stg.RestaurantKey`, and the reconciliation `DELETE` cannot distinguish "missing because
skipped" from "missing because deleted at source". Sorting by an immutable key means updates cannot
reorder anything. Sync workloads see far more updates than deletes, so this — not payload size — is
what the dedicated operation buys.

**Offset paging is safe in this sample, but would not be on a busy source.** The sample source is
static while a run is in flight, so no scan can drift. Against a live table the delta scan has a
narrower version of the same risk: its window is bounded by a pinned `updatedThrough`, so a row
updated past that bound leaves the result set mid-scan and shifts the rows behind it. Because the
watermark advances to `MAX(LastUpdatedDateTime)` over the rows that were *actually staged*, a skipped
row whose timestamp falls below that maximum would be missed permanently rather than retried. The
`@ExpectedKeyCount` / `@ExpectedDeltaCount` guards turn that into a failed run rather than silent
data loss — a drifting scan produces a count mismatch — but note the converse: on a source with
constant write traffic those guards will trip regularly, because the counts are sampled before the
scans begin. Failing often is the correct behaviour for offset paging on a moving table; the answer
is to stop using offset paging, not to loosen the guards.

The production fix is keyset (cursor) pagination — resume from the last value seen, not from a row
count, so shifting rows are irrelevant:

```sql
WHERE (LastUpdatedDateTime > @afterTs)
   OR (LastUpdatedDateTime = @afterTs AND RestaurantId > @afterId)
```

Two things make that more work in ADF than it looks. A Copy activity writes to its sink and exposes
only row counts, so the next cursor cannot be read from the response — it has to come from a second
Web activity per page, or from a `Lookup` against staging after each page (`SELECT TOP 1 … ORDER BY
LastUpdatedDateTime DESC, RestaurantId DESC`). And a cursor containing a timestamp walks straight
back into ADF's datetime coercion (see *Gotchas*), so it should be encoded opaquely in SQL — base64,
Relay-style — and treated as a meaningless string by the pipeline.

**Consuming someone else's GraphQL API?** Ask for a cursor (`first` / `after`) before asking for
sorting: Relay-style connections are the most standardized pagination pattern in GraphQL and are
immune to drift by construction. If sorting is the only thing on offer, the idiomatic — and safe —
shape constrains the sort key to an **enum** rather than free text. The spellings vary (GitHub
`orderBy: { field: CREATED_AT, direction: DESC }`, Shopify `sortKey: CREATED_AT, reverse: true`,
Hasura `order_by: { created_at: desc }`, HotChocolate `[UseSorting]`), but all of them generate a
closed set of values from the schema. An API that accepts a free-text column *name* is a red flag:
column names cannot be parameterized, so it is an injection risk in naive implementations and an easy
denial of service in all of them, since an unindexed sort means a table scan and a sort spill.

**Both halves of the load are verified before anything is applied.** `usp_ApplyRestaurantSync`
compares the staged key set against the row count the API reported at the start of the run
(`@ExpectedKeyCount`, error `50001`) *and* the staged delta against the number of rows the API
reported inside the watermark window (`@ExpectedDeltaCount`, error `50003`). The second guard exists
because a GraphQL error arrives with HTTP 200: the Copy activity still "succeeds" but stages no rows,
which is indistinguishable from a short final page, so the paging loop ends early. Without the check
a partial delta would be merged *and the watermark would still advance*, and the rows that were
missed would never be revisited. Both guards fail the whole run instead of applying a partial result
— the watermark only moves on a complete load, so any failure is recovered by simply running again.

Both counts are `COUNT_BIG(DISTINCT RestaurantId)`, not `COUNT_BIG(1)`, and that distinction matters
in both directions. Every Copy activity has a retry policy, so a retry that fires after rows were
already committed leaves duplicates in staging; the `MERGE` and the `DELETE` are set-based and
already tolerate that, so a raw row count would be the only thing in the procedure that fails a run
purely because a page was retried. In the other direction, `stg.RestaurantKey.RestaurantId` is
deliberately nullable so a malformed page lands as `NULL` rather than failing the copy — and a raw
count would happily count those `NULL`s toward the expected total, letting an incomplete key harvest
pass the guard and delete live rows. Counting distinct non-`NULL` keys is what closes both.

**`MERGE` updates only genuinely changed rows** using `EXISTS (SELECT s.* EXCEPT SELECT t.*)`, which
is NULL-safe, and reports counts via `OUTPUT $action`.

**`ApplySync` is a `Lookup`, not a stored-procedure activity**, so the insert/update/delete counts
come back in the pipeline output where tests and monitoring can see them.

**`etl` procedures run `WITH EXECUTE AS OWNER`**, so the ADF identity needs only
`EXECUTE ON SCHEMA::etl` — not the `ALTER` permission that `TRUNCATE TABLE` normally requires.

### Why not Mapping Data Flows?

A reasonable question, since data flows are ADF's declarative transformation engine. (They are not
an alternative to pipelines — a data flow *runs inside* a pipeline via an `Execute Data Flow`
activity. The real question is whether to replace the Copy activities and `ApplySync` with one.)

**Extraction can't work.** REST is a supported data flow source, but the source transformation
exposes only `requestMethod`, `relativeUrl`, `additionalHeaders`, `httpRequestTimeout`,
`requestInterval` and `QueryParameters` — there is **no `requestBody` property**, which the Copy
activity's REST source does have. GraphQL requires `POST` with a `{"query": …, "variables": …}`
body, so there is no supported way to issue the query. The only workaround is `GET` with `?query=`
(HotChocolate accepts it) and driving `skip` through pagination rules as a query parameter — which
means URL-encoding GraphQL documents. Data flows also issue N+1 requests for N pages, because one
extra call is made to infer the schema.

**The load half is possible, but worse here.** An `AlterRow` transformation into an Azure SQL sink
with `insertable`/`updateable`/`deletable` would express the same intent, but it would give up:

* **Atomicity** — the merge, the delete and the watermark advance are currently one transaction; a
  sink cannot span that with the watermark update.
* **The safety guards** — the `@ExpectedKeyCount` / `@ExpectedDeltaCount` checks that abort the run
  when either harvest was incomplete are a few lines of T-SQL and awkward to express in a data flow.
* **Cost and start-up time** — data flows need a Spark cluster (roughly 4–6 minutes cold, about a
  minute on a TTL-enabled integration runtime). The whole pipeline currently finishes in 2–3 minutes
  with no cluster at all.

Azure SQL's `MERGE` is already set-based and transactional, so the merge belongs in the database.

**Data flows would be the better choice** when the sink cannot merge itself (Delta, Parquet, blob,
Synapse dedicated pools), when volumes are large enough that a single SQL transaction is unwise, or
when there is real transformation work — multi-source joins, aggregations, pivots, deduplication,
schema drift, data-quality asserts. None of that applies to one source of flat rows landing in a
SQL table.

**If this had to scale**, the first change would not be adopting data flows — it would be replacing
`OFFSET` paging with keyset pagination (see *Offset paging is safe in this sample* above), which
matters for correctness under concurrent writes as well as for speed, since `OFFSET` also degrades as
the offset grows. Spark pays off for transformation complexity, not row count alone.

---

## Repository layout

```
sql/
  01-source-schema.sql          Source table + trigger + index + 75 sample rows (idempotent)
  02-source-grant-api-sami.sql  App Service SAMI -> db_datareader on the source DB
  03-dest-schema.sql            Destination tables, watermark control, etl.* procedures (idempotent)
  04-dest-grant-adf-sami.sql    ADF SAMI -> db_datareader + db_datawriter + EXECUTE ON SCHEMA::etl
  05-source-changes.sql         Test fixture: 3 updates, 2 inserts, 2 deletes

src/GraphQlApi/               .NET 10 ASP.NET Core minimal API + HotChocolate 16
  Program.cs                    Hosting, GraphQL server, /healthz
  GraphQL/Query.cs              Read-only root query (no mutations)
  Data/RestaurantRepository.cs  All SQL access, page size 30, transient-error retry
  Models/                       Restaurant, RestaurantKey, SyncWatermark, Page<T>

adf/
  linkedService/                LS_GraphQlApi (anonymous REST), LS_DestinationSql (SAMI)
  dataset/                      REST source + three Azure SQL datasets
  pipeline/                     PL_Sync_Restaurants_GraphQL_To_Sql

scripts/
  Invoke-SqlScript.ps1          Runs .sql files or inline queries with an Entra token
  Deploy-Api.ps1                Configures App Service, publishes, zip-deploys
  Deploy-Adf.ps1                PUTs the ADF JSON via the management API
  Invoke-PipelineRun.ps1        Triggers the pipeline, waits, prints + returns run statistics
  Test-SyncIntegrity.ps1        SHA2-256 row fingerprint: source vs destination
  Reset-Destination.ps1         Empties the target and rewinds the watermark
  Test-EndToEnd.ps1             The full three-scenario test suite
```

---

## Deploying

Prerequisites: Azure CLI (signed in, with an account that is an Entra admin on the SQL server),
.NET 10 SDK, PowerShell 7.

Run from the `scripts` folder, **in this order**:

```powershell
cd scripts

# 1. Source database: table + sample data, then grant the API's managed identity read access.
./Invoke-SqlScript.ps1 -Database 'nyc-dohmh-adf-graphql-to-sql-1' -Path '../sql/01-source-schema.sql'
./Invoke-SqlScript.ps1 -Database 'nyc-dohmh-adf-graphql-to-sql-1' -Path '../sql/02-source-grant-api-sami.sql'

# 2. Build and deploy the GraphQL API.
./Deploy-Api.ps1

# 3. Destination database: schema + ETL procedures, then grant ADF's managed identity read/write.
./Invoke-SqlScript.ps1 -Database 'nyc-dohmh-adf-graphql-to-sql-2' -Path '../sql/03-dest-schema.sql'
./Invoke-SqlScript.ps1 -Database 'nyc-dohmh-adf-graphql-to-sql-2' -Path '../sql/04-dest-grant-adf-sami.sql'

# 4. Deploy the Data Factory artifacts.
./Deploy-Adf.ps1

# 5. Run the pipeline.
./Invoke-PipelineRun.ps1
```

> `03-dest-schema.sql` is destructive by design: it drops and recreates the destination objects and
> rewinds the watermark to `1900-01-01`, so the next run is a full load.

---

## The GraphQL API

Endpoint: `POST https://<app-service>/graphql` — **anonymous, no user authentication**, read-only
(there are no mutations). Health probe: `GET /healthz`. Introspection is enabled, so the schema is
browsable from any GraphQL client.

Send `Accept: application/json`. Without it HotChocolate replies with
`application/graphql-response+json`, which ADF's REST source cannot parse.

```graphql
type Query {
  "One page (30 rows) of restaurants, optionally restricted to a watermark window."
  restaurants(updatedAfter: String, updatedThrough: String, skip: Int! = 0): PageOfRestaurant!

  "One page (30 rows) of primary keys for every row that currently exists at the source."
  restaurantKeys(skip: Int! = 0): PageOfRestaurantKey!

  "Current high-water mark and row count of the source table."
  restaurantWatermark: SyncWatermark!
}

type Restaurant {
  restaurantId: Int!
  name: String!
  borough: String!
  cuisine: String!
  inspectionGrade: String
  inspectionScore: Int
  seatingCapacity: Int!
  isActive: Boolean!
  createDateTime: String!       # yyyy-MM-ddTHH:mm:ss.fff  (UTC)
  lastUpdatedDateTime: String!  # yyyy-MM-ddTHH:mm:ss.fff  (UTC)
}

type RestaurantKey {
  restaurantId: Int!
}

type SyncWatermark {
  maxLastUpdatedDateTime: String   # null only when the table is empty
  rowCount: Int!
  serverUtcNow: String!
}

# PageOfRestaurant / PageOfRestaurantKey
type PageOfRestaurant {
  items: [Restaurant!]!
  pageSize: Int!        # always 30
  skip: Int!            # the offset this page was read from
  totalCount: Int!      # rows matching the filter, across all pages
  returnedCount: Int!
  hasNextPage: Boolean!
  nextSkip: Int         # feed straight back into `skip`; null on the last page
}
```

Example delta page:

```bash
curl -s https://<app-service>/graphql \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"query":"query($a:String,$t:String,$s:Int!){ restaurants(updatedAfter:$a,updatedThrough:$t,skip:$s){ totalCount hasNextPage nextSkip items{ restaurantId name lastUpdatedDateTime } } }","variables":{"a":"2026-09-01T00:00:00.000","t":"2026-09-14T12:00:01.728","s":0}}'
```

---

## Testing

```powershell
cd scripts
./Test-EndToEnd.ps1
```

| Test | Scenario | Expected |
|------|----------|----------|
| 1 | Full load into an empty destination | 75 inserted, 0 updated, 0 deleted |
| 2 | Re-run with no source changes | **0 delta rows read**, 0/0/0 |
| 3 | 3 rows updated, 2 inserted, 2 deleted at the source | 2 inserted, 3 updated, 2 deleted |

After every run the destination is fingerprinted against the source with SHA2-256 over **all**
columns, including millisecond timestamps, so "it ran" is never mistaken for "it is correct".
The suite restores the source table and empties the destination when it finishes.

Test 2 is the important one. If a single millisecond is lost anywhere in the watermark round trip,
the newest row is re-read on **every** run forever. Individual pieces can also be run on their own:

```powershell
./Reset-Destination.ps1      # empty the target, rewind the watermark
./Invoke-PipelineRun.ps1     # trigger a run and print its statistics
./Test-SyncIntegrity.ps1     # compare source and destination fingerprints
```

---

## Gotchas discovered while building this

These all cost real debugging time and are the reason several pieces look the way they do.

**1. Managed identities must be mapped in Azure SQL by client ID, not object ID.**
Using the object ID produces `Login failed for user '<token-identified principal>'`, which gives no
hint about the cause. Both grant scripts build the SID from the **application (client) ID**:

```sql
DECLARE @sid VARBINARY(16) = CAST(CAST(@clientId AS UNIQUEIDENTIFIER) AS VARBINARY(16));
EXEC('CREATE USER [name] WITH SID = ' + CONVERT(NVARCHAR(100), @sid, 1) + ', TYPE = E;');
```

**2. Azure Data Factory truncates date-like stored-procedure arguments to whole seconds.**
This happens *even when the parameter is declared as a string* — the value is coerced through a
`DateTime` and re-formatted (`2026-09-14T12:00:01.728` → `9/14/2026 12:00:01 PM`). Passing the new
watermark as an argument therefore silently dropped the milliseconds and made every run re-read the
newest row. The fix: **do not pass the watermark to SQL at all.** `usp_ApplyRestaurantSync` derives
it from the rows that were actually staged — `MAX(stg.Restaurant.LastUpdatedDateTime)` — which
travel through the Copy activity's column mapping and keep full precision. Because the delta window
was `(old, pinned upper bound]`, the staged rows contain every change in that window, so their
maximum is the correct and safest new lower bound.

**3. ADF's JSON layer rewrites anything that looks like a timestamp.** A string variable set to
`2026-09-14T12:00:01.728` is reported as `2026-09-14T12:00:01.728Z`, and trailing zeros in the
fraction are dropped. Harmless for the REST request body, fatal for `CONVERT(..., 126)`.

**4. GraphQL returns errors with HTTP 200.** A Web activity will happily "succeed" on a failed
query, and the run then dies later with `property 'data' doesn't exist`. `CheckSourceWatermarkResponse`
exists purely to turn that into a readable message.

**5. HotChocolate replies with `application/graphql-response+json`** unless the request sends
`Accept: application/json`. ADF's REST source cannot parse the former. Both `Content-Type` and
`Accept` are set in the Copy activity's `additionalHeaders`.

**6. HotChocolate 16 removed `IRequestExecutorBuilder.RegisterService<T>()`** — resolver method
parameters are injected automatically. Also, **error filters are activated from HotChocolate's
isolated schema service container**, which has no `ILogger<T>`, so a class-based
`AddErrorFilter<T>()` throws at startup. The delegate overload is used instead, and logging happens
in the repository.

**7. `<InvariantGlobalization>true</InvariantGlobalization>` breaks `Microsoft.Data.SqlClient`**
("Globalization Invariant Mode is not supported"). It must not be set.

**8. `Microsoft.Data.SqlClient` 7.x moved the Entra auth providers into a separate package.**
Without `Microsoft.Data.SqlClient.Extensions.Azure` you get
"Cannot find an authentication provider for 'ActiveDirectoryDefault'". That package requires
`Azure.Identity >= 1.18.0`.

**9. Free-limit serverless databases cannot have auto-pause disabled**
(`Only default value for auto pause delay is allowed for Free Limit database`). The first request
after an idle period fails with error `40613` while the database resumes, which can take over a
minute. Transient-error retry is therefore built into every layer: the API repository (12 attempts,
~2 minutes), the PowerShell helpers, and the ADF activity policies (4 retries, 60 s apart).

**10. `CONVERT(datetime2, ..., 126)` omits the fractional seconds when they are zero**, producing an
inconsistent string width between runs. `FORMAT(value, 'yyyy-MM-ddTHH:mm:ss.fff', 'en-US')` is used
instead — the culture must be explicit because `:` is a culture-dependent time separator in .NET
custom format strings.

**11. ADF artifacts are deployed by PUTting JSON to the management API**, not via an ARM template.
ARM would try to evaluate JSONPath column mappings such as `['restaurantId']` as expressions,
because they start with `[`.

**12. PowerShell:** `DataTable.Load($reader)` advances the reader itself, so a manual `NextResult()`
loop silently skips result sets — use `SqlDataAdapter.Fill($dataSet)`. And returning a `DataTable`
from a function unrolls it into `DataRow`s unless you write `return , $table`.

---

## Azure resources used

| Resource | Name |
|----------|------|
| Resource group | `nyc-dohmh-adf-graphql-to-sql` |
| SQL server | `nyc-dohmh-adf-graphql-to-sql` (Entra-only auth) |
| Source database | `nyc-dohmh-adf-graphql-to-sql-1` |
| Destination database | `nyc-dohmh-adf-graphql-to-sql-2` |
| App Service | `nyc-dohmh-adf-graphql-to-sql` (Windows, .NET 10, 64-bit, Always On) |
| Data Factory | `nyc-dohmh-adf-graphql-to-sql` |

The App Service reads the source database through the connection string `SourceDatabase`
(`Authentication=Active Directory Managed Identity`). Running locally, the same connection string
resolves to your Azure CLI or Visual Studio sign-in, so no configuration change is needed.
