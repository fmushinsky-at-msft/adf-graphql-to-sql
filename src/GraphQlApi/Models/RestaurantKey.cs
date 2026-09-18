namespace NycDohmh.GraphQlApi.Models;

/// <summary>
/// Just the primary key of a source row. Azure Data Factory pages through the full key set to
/// work out which rows were hard-deleted at the source, because a watermark delta on its own can
/// never reveal a deleted row.
/// </summary>
/// <param name="RestaurantId">Single-column primary key of the source table.</param>
public sealed record RestaurantKey(int RestaurantId);
