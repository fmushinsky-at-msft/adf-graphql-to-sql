/* =====================================================================================
   Source database: nyc-dohmh-adf-graphql-to-sql-1

   Applies a deterministic set of changes so the incremental sync can be observed doing
   both of its operations in a single run:

	 * 3 rows updated  -> ids 3, 17, 42   (the trigger moves LastUpdatedDateTime forward,
										   so they fall inside the next delta window)
	 * 2 rows inserted -> ids 76, 77

   The source never deletes rows, so there is no delete scenario.

   Re-run sql/01-source-schema.sql to put the source table back to its original 75 rows.
   ===================================================================================== */

SET NOCOUNT ON;
GO

UPDATE demo.Restaurant
	SET SeatingCapacity = SeatingCapacity + 25,
		InspectionGrade = 'A',
		InspectionScore = 7
WHERE RestaurantId IN (3, 17, 42);
GO

INSERT INTO demo.Restaurant (RestaurantId, Name, Borough, Cuisine, InspectionGrade, InspectionScore, SeatingCapacity, IsActive)
VALUES
	(76, N'Harbor Light Oyster Bar', N'Staten Island', N'Seafood',   'A', 9,  64, 1),
	(77, N'Sunnyside Samosa House',  N'Queens',        N'Indian',    'B', 18, 28, 1);
GO

SELECT
	RowCountTotal = COUNT_BIG(1),
	MaxWatermark  = FORMAT(MAX(LastUpdatedDateTime), 'yyyy-MM-ddTHH:mm:ss.fff', 'en-US')
FROM demo.Restaurant;
GO
