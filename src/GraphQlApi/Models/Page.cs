namespace NycDohmh.GraphQlApi.Models;

/// <summary>
/// A single page of results. The page size is fixed by the service (see <see cref="Data.RestaurantRepository.PageSize"/>)
/// so that consumers such as Azure Data Factory can rely on a stable paging contract.
/// </summary>
/// <typeparam name="T">The item type contained in the page.</typeparam>
public sealed class Page<T>
{
    public required IReadOnlyList<T> Items { get; init; }

    /// <summary>Number of rows requested per page. Always 30.</summary>
    public required int PageSize { get; init; }

    /// <summary>Zero-based offset of the first row in this page.</summary>
    public required int Skip { get; init; }

    /// <summary>Total number of rows matching the query across all pages.</summary>
    public required int TotalCount { get; init; }

    /// <summary>Number of rows actually returned in this page.</summary>
    public int ReturnedCount => Items.Count;

    /// <summary>True when another page is available; callers should request <see cref="NextSkip"/>.</summary>
    public bool HasNextPage => Skip + Items.Count < TotalCount;

    /// <summary>The <c>skip</c> value to pass to fetch the next page, or <c>null</c> when this is the last page.</summary>
    public int? NextSkip => HasNextPage ? Skip + Items.Count : null;
}
