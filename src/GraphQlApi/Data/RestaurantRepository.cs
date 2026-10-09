using Microsoft.Data.SqlClient;
using NycDohmh.GraphQlApi.Models;

namespace NycDohmh.GraphQlApi.Data;

/// <summary>
/// Read-only data access over <c>demo.Restaurant</c> in the source database.
/// Authentication is handled entirely by the connection string
/// (<c>Authentication=Active Directory Default</c>), which resolves to the App Service
/// system-assigned managed identity when running in Azure and to the developer's Azure CLI /
/// Visual Studio sign-in when running locally. No secrets are stored anywhere.
/// </summary>
public sealed class RestaurantRepository(IConfiguration configuration, ILogger<RestaurantRepository> logger)
{
    /// <summary>Fixed page size for every paged query exposed by this service.</summary>
    public const int PageSize = 30;

    /// <summary>
    /// Canonical timestamp format used on the wire: UTC, ISO-8601, millisecond precision, no offset.
    /// This matches <c>datetime2(3)</c> exactly and converts implicitly in T-SQL, which keeps the
    /// Azure Data Factory watermark comparisons unambiguous.
    /// </summary>
    public const string TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fff";

    private const string ProjectionColumns = """
        r.RestaurantId,
        r.Name,
        r.Borough,
        r.Cuisine,
        r.InspectionGrade,
        r.InspectionScore,
        r.SeatingCapacity,
        r.IsActive,
        r.CreateDateTime,
        r.LastUpdatedDateTime
        """;

    // The ORDER BY text is picked from this closed set by the RestaurantSort enum. Caller input is
    // never concatenated into SQL, and a column name could not be parameterized anyway.
    private static readonly string PageSqlOldestFirst = BuildPageSql("r.LastUpdatedDateTime, r.RestaurantId");

    private static readonly string PageSqlNewestFirst = BuildPageSql("r.LastUpdatedDateTime DESC, r.RestaurantId DESC");

    // Azure SQL serverless databases auto-pause. The first request after an idle period fails with
    // 40613 while the database resumes, so transient failures are retried here. Resuming a paused
    // database routinely takes over a minute, so the retry budget below is deliberately generous.
    private static readonly int[] TransientErrorNumbers = [40613, 40501, 40197, 49918, 49919, 49920, 4060, 10928, 10929, 11001, 233, -2];

    private const int MaxAttempts = 12;

    private string ConnectionString =>
        configuration.GetConnectionString("SourceDatabase")
        ?? throw new InvalidOperationException("Connection string 'SourceDatabase' is not configured.");

    /// <summary>
    /// Returns one page of rows, optionally restricted to a watermark window.
    /// Both orderings end in <c>RestaurantId</c>, so rows that share a timestamp keep a fixed
    /// position and offset paging is deterministic.
    /// </summary>
    public async Task<Page<Restaurant>> GetRestaurantsAsync(
        DateTime? updatedAfter,
        DateTime? updatedThrough,
        RestaurantSort sort,
        int skip,
        CancellationToken cancellationToken)
    {
        skip = Math.Max(0, skip);

        var sql = sort switch
        {
            RestaurantSort.LastUpdatedAsc => PageSqlOldestFirst,
            RestaurantSort.LastUpdatedDesc => PageSqlNewestFirst,
            _ => throw new ArgumentOutOfRangeException(nameof(sort), sort, "Unsupported sort order.")
        };

        return await ExecuteWithRetryAsync(async connection =>
        {
            await using var command = new SqlCommand(sql, connection);
            command.Parameters.Add("@updatedAfter", System.Data.SqlDbType.DateTime2).Value = (object?)updatedAfter ?? DBNull.Value;
            command.Parameters.Add("@updatedThrough", System.Data.SqlDbType.DateTime2).Value = (object?)updatedThrough ?? DBNull.Value;
            command.Parameters.Add("@skip", System.Data.SqlDbType.Int).Value = skip;
            command.Parameters.Add("@take", System.Data.SqlDbType.Int).Value = PageSize;

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);

            await reader.ReadAsync(cancellationToken);
            var totalCount = (int)reader.GetInt64(0);

            await reader.NextResultAsync(cancellationToken);

            var items = new List<Restaurant>(PageSize);
            while (await reader.ReadAsync(cancellationToken))
            {
                items.Add(new Restaurant(
                    RestaurantId: reader.GetInt32(0),
                    Name: reader.GetString(1),
                    Borough: reader.GetString(2),
                    Cuisine: reader.GetString(3),
                    InspectionGrade: reader.IsDBNull(4) ? null : reader.GetString(4).TrimEnd(),
                    InspectionScore: reader.IsDBNull(5) ? null : reader.GetInt32(5),
                    SeatingCapacity: reader.GetInt32(6),
                    IsActive: reader.GetBoolean(7),
                    CreateDateTime: FormatTimestamp(reader.GetDateTime(8)),
                    LastUpdatedDateTime: FormatTimestamp(reader.GetDateTime(9))));
            }

            return new Page<Restaurant>
            {
                Items = items,
                PageSize = PageSize,
                Skip = skip,
                TotalCount = totalCount
            };
        }, cancellationToken);
    }

    private static string BuildPageSql(string orderBy) => $"""
        SELECT COUNT_BIG(1)
        FROM demo.Restaurant AS r
        WHERE (@updatedAfter   IS NULL OR r.LastUpdatedDateTime >  @updatedAfter)
          AND (@updatedThrough IS NULL OR r.LastUpdatedDateTime <= @updatedThrough);

        SELECT
            {ProjectionColumns}
        FROM demo.Restaurant AS r
        WHERE (@updatedAfter   IS NULL OR r.LastUpdatedDateTime >  @updatedAfter)
          AND (@updatedThrough IS NULL OR r.LastUpdatedDateTime <= @updatedThrough)
        ORDER BY {orderBy}
        OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY;
        """;

    private static string FormatTimestamp(DateTime value) =>
        value.ToString(TimestampFormat, System.Globalization.CultureInfo.InvariantCulture);

    private async Task<T> ExecuteWithRetryAsync<T>(
        Func<SqlConnection, Task<T>> operation,
        CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await using var connection = new SqlConnection(ConnectionString);
                await connection.OpenAsync(cancellationToken);
                return await operation(connection);
            }
            catch (SqlException ex) when (TransientErrorNumbers.Contains(ex.Number) && attempt < MaxAttempts)
            {
                var delay = TimeSpan.FromSeconds(Math.Min(15, attempt * 5));
                logger.LogWarning(
                    ex,
                    "Transient SQL error {ErrorNumber} on attempt {Attempt}/{MaxAttempts}. The serverless database may be resuming. Retrying in {Delay}.",
                    ex.Number,
                    attempt,
                    MaxAttempts,
                    delay);
                await Task.Delay(delay, cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Logged here because the GraphQL layer only returns a generic message to callers.
                logger.LogError(ex, "Source database query failed on attempt {Attempt}.", attempt);
                throw;
            }
        }
    }
}
