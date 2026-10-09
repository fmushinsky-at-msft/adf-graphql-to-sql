namespace NycDohmh.GraphQlApi.Models;

/// <summary>
/// The orderings a caller can choose for the <c>restaurants</c> query. It is a closed enum rather
/// than a free-text column name, so the service only ever runs one of a fixed set of
/// <c>ORDER BY</c> clauses. Ties on the timestamp are always broken by <c>RestaurantId</c>, so
/// every ordering is deterministic and offset paging is repeatable.
/// </summary>
public enum RestaurantSort
{
    /// <summary>Oldest change first. The default, and the order to page a delta in.</summary>
    LastUpdatedAsc,

    /// <summary>
    /// Newest change first. With <c>skip: 0</c> the first row carries the highest
    /// <c>lastUpdatedDateTime</c> at the source, which is the current high-water mark.
    /// </summary>
    LastUpdatedDesc
}
