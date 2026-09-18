using System.Globalization;
using NycDohmh.GraphQlApi.Data;
using NycDohmh.GraphQlApi.Models;

namespace NycDohmh.GraphQlApi.GraphQL;

/// <summary>
/// Read-only GraphQL root query. There are deliberately no mutations: this API is a
/// publishing surface for the source table, not a write API.
/// </summary>
public sealed class Query
{
    /// <summary>
    /// Returns one page (30 rows) of restaurants, optionally restricted to a watermark window.
    /// </summary>
    /// <param name="updatedAfter">
    /// Exclusive lower bound on <c>lastUpdatedDateTime</c>. Pass the previously stored watermark.
    /// UTC, ISO-8601, no offset (for example <c>2026-09-14T12:00:01.000</c>). Omit for a full load.
    /// </param>
    /// <param name="updatedThrough">
    /// Inclusive upper bound on <c>lastUpdatedDateTime</c>. Pass the value returned by
    /// <c>restaurantWatermark.maxLastUpdatedDateTime</c> at the start of the run so that the
    /// result set stays stable while the consumer pages through it.
    /// </param>
    /// <param name="skip">Zero-based row offset. Use <c>nextSkip</c> from the previous page.</param>
    public Task<Page<Restaurant>> GetRestaurantsAsync(
        RestaurantRepository repository,
        CancellationToken cancellationToken,
        string? updatedAfter = null,
        string? updatedThrough = null,
        int skip = 0) =>
        repository.GetRestaurantsAsync(
            ParseTimestamp(updatedAfter, nameof(updatedAfter)),
            ParseTimestamp(updatedThrough, nameof(updatedThrough)),
            skip,
            cancellationToken);

    /// <summary>
    /// Returns one page (30 rows) of primary keys for every row that currently exists at the
    /// source. Consumers reconcile this against their copy to find rows that were deleted.
    /// </summary>
    /// <param name="skip">Zero-based row offset. Use <c>nextSkip</c> from the previous page.</param>
    public Task<Page<RestaurantKey>> GetRestaurantKeysAsync(
        RestaurantRepository repository,
        CancellationToken cancellationToken,
        int skip = 0) =>
        repository.GetRestaurantKeysAsync(skip, cancellationToken);

    /// <summary>
    /// Returns the current high-water mark of the source table. Read this once at the start of an
    /// incremental load and use it as the upper bound of the delta window.
    /// </summary>
    public Task<SyncWatermark> GetRestaurantWatermarkAsync(
        RestaurantRepository repository,
        CancellationToken cancellationToken) =>
        repository.GetWatermarkAsync(cancellationToken);

    private static DateTime? ParseTimestamp(string? value, string argumentName)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        if (!DateTime.TryParse(
                value,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal,
                out var parsed))
        {
            throw new GraphQLException(
                ErrorBuilder.New()
                    .SetMessage($"'{argumentName}' must be an ISO-8601 UTC timestamp such as '2026-09-14T12:00:01.000'.")
                    .SetCode("INVALID_TIMESTAMP")
                    .Build());
        }

        return parsed;
    }
}
