namespace NycDohmh.GraphQlApi.Models;

/// <summary>
/// The high-water mark of the source table. Azure Data Factory reads this once at the start of a
/// pipeline run and uses it as the upper bound of the delta window, which keeps offset paging
/// stable even if rows change while the pipeline is still paging.
/// </summary>
/// <param name="MaxLastUpdatedDateTime">
/// Highest <c>LastUpdatedDateTime</c> in the source table. UTC, ISO-8601 with no offset.
/// Null only when the table is empty.
/// </param>
/// <param name="RowCount">Total number of rows currently in the source table.</param>
/// <param name="ServerUtcNow">Current UTC time of the source database server.</param>
public sealed record SyncWatermark(
    string? MaxLastUpdatedDateTime,
    int RowCount,
    string ServerUtcNow);
