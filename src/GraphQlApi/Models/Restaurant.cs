namespace NycDohmh.GraphQlApi.Models;

/// <summary>
/// A restaurant row served from <c>demo.Restaurant</c> in the source database.
/// </summary>
/// <param name="RestaurantId">Single-column primary key of the source table.</param>
/// <param name="Name">Registered business name.</param>
/// <param name="Borough">NYC borough the establishment operates in.</param>
/// <param name="Cuisine">Primary cuisine description.</param>
/// <param name="InspectionGrade">Most recent inspection letter grade, if graded.</param>
/// <param name="InspectionScore">Most recent inspection score, if scored.</param>
/// <param name="SeatingCapacity">Permitted seating capacity.</param>
/// <param name="IsActive">Whether the permit is currently active.</param>
/// <param name="CreateDateTime">Audit field. UTC, ISO-8601 with no offset (yyyy-MM-ddTHH:mm:ss.fff).</param>
/// <param name="LastUpdatedDateTime">Audit field driving watermark deltas. UTC, ISO-8601 with no offset.</param>
public sealed record Restaurant(
    int RestaurantId,
    string Name,
    string Borough,
    string Cuisine,
    string? InspectionGrade,
    int? InspectionScore,
    int SeatingCapacity,
    bool IsActive,
    string CreateDateTime,
    string LastUpdatedDateTime);
