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
    /// Ordering is by (LastUpdatedDateTime, RestaurantId) so that offset paging is deterministic.
    /// </summary>
    public async Task<Page<Restaurant>> GetRestaurantsAsync(
        DateTime? updatedAfter,
        DateTime? updatedThrough,
        int skip,
        CancellationToken cancellationToken)
    {
        skip = Math.Max(0, skip);

        const string sql = $"""
            SELECT COUNT_BIG(1)
            FROM demo.Restaurant AS r
            WHERE (@updatedAfter   IS NULL OR r.LastUpdatedDateTime >  @updatedAfter)
              AND (@updatedThrough IS NULL OR r.LastUpdatedDateTime <= @updatedThrough);

            SELECT
                {ProjectionColumns}
            FROM demo.Restaurant AS r
            WHERE (@updatedAfter   IS NULL OR r.LastUpdatedDateTime >  @updatedAfter)
              AND (@updatedThrough IS NULL OR r.LastUpdatedDateTime <= @updatedThrough)
            ORDER BY r.LastUpdatedDateTime, r.RestaurantId
            OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY;
            """;

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

    /// <summary>
    /// Returns one page of primary keys ordered by <c>RestaurantId</c>. Consumers page through the
    /// full key set to detect rows that were hard-deleted at the source.
    /// </summary>
    public async Task<Page<RestaurantKey>> GetRestaurantKeysAsync(int skip, CancellationToken cancellationToken)
    {
        skip = Math.Max(0, skip);

        const string sql = """
            SELECT COUNT_BIG(1) FROM demo.Restaurant;

            SELECT r.RestaurantId
            FROM demo.Restaurant AS r
            ORDER BY r.RestaurantId
            OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY;
            """;

        return await ExecuteWithRetryAsync(async connection =>
        {
            await using var command = new SqlCommand(sql, connection);
            command.Parameters.Add("@skip", System.Data.SqlDbType.Int).Value = skip;
            command.Parameters.Add("@take", System.Data.SqlDbType.Int).Value = PageSize;

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);

            await reader.ReadAsync(cancellationToken);
            var totalCount = (int)reader.GetInt64(0);

            await reader.NextResultAsync(cancellationToken);

            var items = new List<RestaurantKey>(PageSize);
            while (await reader.ReadAsync(cancellationToken))
            {
                items.Add(new RestaurantKey(reader.GetInt32(0)));
            }

            return new Page<RestaurantKey>
            {
                Items = items,
                PageSize = PageSize,
                Skip = skip,
                TotalCount = totalCount
            };
        }, cancellationToken);
    }

    /// <summary>Returns the current high-water mark and row count of the source table.</summary>
    public async Task<SyncWatermark> GetWatermarkAsync(CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                MaxLastUpdatedDateTime = MAX(r.LastUpdatedDateTime),
                RowCount_             = COUNT_BIG(1),
                ServerUtcNow          = SYSUTCDATETIME()
            FROM demo.Restaurant AS r;
            """;

        return await ExecuteWithRetryAsync(async connection =>
        {
            await using var command = new SqlCommand(sql, connection);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            await reader.ReadAsync(cancellationToken);

            return new SyncWatermark(
                MaxLastUpdatedDateTime: reader.IsDBNull(0) ? null : FormatTimestamp(reader.GetDateTime(0)),
                RowCount: (int)reader.GetInt64(1),
                ServerUtcNow: FormatTimestamp(reader.GetDateTime(2)));
        }, cancellationToken);
    }

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
