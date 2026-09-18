/* =====================================================================================
   Source database: nyc-dohmh-adf-graphql-to-sql-1

   Applies a deterministic set of changes so the incremental sync can be observed doing
   all three operations in a single run:

	 * 3 rows updated  -> ids 3, 17, 42   (the trigger moves LastUpdatedDateTime forward,
										   so they fall inside the next delta window)
	 * 2 rows inserted -> ids 76, 77
	 * 2 rows deleted  -> ids 8, 55       (a delta read can never see these, which is why
										   the pipeline also reconciles the full key set)

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

DELETE FROM demo.Restaurant WHERE RestaurantId IN (8, 55);
GO

SELECT
	RowCountTotal = COUNT_BIG(1),
	MaxWatermark  = FORMAT(MAX(LastUpdatedDateTime), 'yyyy-MM-ddTHH:mm:ss.fff', 'en-US')
FROM demo.Restaurant;
GO
