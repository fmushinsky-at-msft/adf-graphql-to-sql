/* =====================================================================================
   Destination database: nyc-dohmh-adf-graphql-to-sql-2

   Objects that receive the incremental (watermark) load from the GraphQL API via ADF:

	 dbo.Restaurant        Target table. Starts empty and is filled incrementally.
	 stg.Restaurant        Landing zone for the delta rows of the current pipeline run.
	 stg.RestaurantKey     Landing zone for the full source key set, used to detect deletes.
	 dbo.WatermarkControl  Stores the high-water mark plus run statistics.
	 etl.usp_*             The procedures the pipeline calls.

   This script is idempotent - re-running it recreates everything and resets the watermark.
   ===================================================================================== */

SET NOCOUNT ON;
GO

IF SCHEMA_ID('stg') IS NULL EXEC ('CREATE SCHEMA stg AUTHORIZATION dbo;');
IF SCHEMA_ID('etl') IS NULL EXEC ('CREATE SCHEMA etl AUTHORIZATION dbo;');
GO

DROP PROCEDURE IF EXISTS etl.usp_StartRestaurantSync;
DROP PROCEDURE IF EXISTS etl.usp_ApplyRestaurantSync;
DROP PROCEDURE IF EXISTS etl.usp_GetWatermark;
DROP PROCEDURE IF EXISTS etl.usp_ResetRestaurantTarget;
DROP TABLE IF EXISTS stg.Restaurant;
DROP TABLE IF EXISTS stg.RestaurantKey;
DROP TABLE IF EXISTS dbo.Restaurant;
DROP TABLE IF EXISTS dbo.WatermarkControl;
GO

/* ------------------------------------------------------------------ target table -- */
CREATE TABLE dbo.Restaurant
(
	/* Columns mirrored from the source, including the source audit fields. */
	RestaurantId         INT            NOT NULL,
	Name                 NVARCHAR(200)  NOT NULL,
	Borough              NVARCHAR(50)   NOT NULL,
	Cuisine              NVARCHAR(100)  NOT NULL,
	InspectionGrade      CHAR(1)        NULL,
	InspectionScore      INT            NULL,
	SeatingCapacity      INT            NOT NULL,
	IsActive             BIT            NOT NULL,
	CreateDateTime       DATETIME2(3)   NOT NULL,
	LastUpdatedDateTime  DATETIME2(3)   NOT NULL,

	/* ETL audit columns - when this warehouse row was first written and last changed. */
	SyncInsertedDateTime DATETIME2(3)   NOT NULL CONSTRAINT DF_DestRestaurant_Inserted DEFAULT (SYSUTCDATETIME()),
	SyncUpdatedDateTime  DATETIME2(3)   NOT NULL CONSTRAINT DF_DestRestaurant_Updated  DEFAULT (SYSUTCDATETIME()),

	CONSTRAINT PK_DestRestaurant PRIMARY KEY CLUSTERED (RestaurantId)
);
GO

/* ----------------------------------------------------------------- staging tables -- */
/* Heaps with no constraints: Azure Data Factory bulk-inserts one page at a time and the
   procedures below deduplicate, so constraints here would only slow the load down. */
CREATE TABLE stg.Restaurant
(
	RestaurantId        INT            NULL,
	Name                NVARCHAR(200)  NULL,
	Borough             NVARCHAR(50)   NULL,
	Cuisine             NVARCHAR(100)  NULL,
	InspectionGrade     CHAR(1)        NULL,
	InspectionScore     INT            NULL,
	SeatingCapacity     INT            NULL,
	IsActive            BIT            NULL,
	CreateDateTime      DATETIME2(3)   NULL,
	LastUpdatedDateTime DATETIME2(3)   NULL
);
GO

CREATE TABLE stg.RestaurantKey
(
	RestaurantId INT NULL
);
GO

/* --------------------------------------------------------------- watermark control -- */
CREATE TABLE dbo.WatermarkControl
(
	TableName             SYSNAME      NOT NULL,
	/* Highest source LastUpdatedDateTime that has been successfully loaded. */
	WatermarkValue        DATETIME2(3) NOT NULL,
	LastSyncStartDateTime DATETIME2(3) NULL,
	LastSyncEndDateTime   DATETIME2(3) NULL,
	LastRowsInserted      INT          NULL,
	LastRowsUpdated       INT          NULL,
	LastRowsDeleted       INT          NULL,
	CONSTRAINT PK_WatermarkControl PRIMARY KEY CLUSTERED (TableName)
);
GO

/* A watermark far in the past makes the first run a full load. */
INSERT INTO dbo.WatermarkControl (TableName, WatermarkValue)
VALUES (N'demo.Restaurant', '1900-01-01T00:00:00.000');
GO

/* =====================================================================================
   Procedures called by the Azure Data Factory pipeline.

   They run WITH EXECUTE AS OWNER so the ADF managed identity only needs EXECUTE on the
   etl schema - it does not need the ALTER permission that TRUNCATE TABLE normally requires.
   ===================================================================================== */

/* Returns the watermark to use as the lower bound of this run's delta window.

   The value is returned as a string in the exact format the API expects. FORMAT is used rather
   than CONVERT(..., 126) because style 126 omits the fractional seconds when they are zero,
   which would make the format inconsistent between runs. */
CREATE PROCEDURE etl.usp_GetWatermark
	@TableName SYSNAME
AS
BEGIN
	SET NOCOUNT ON;

	SELECT
		TableName      = w.TableName,
		WatermarkValue = FORMAT(w.WatermarkValue, 'yyyy-MM-ddTHH:mm:ss.fff', 'en-US')
	FROM dbo.WatermarkControl AS w
	WHERE w.TableName = @TableName;
END;
GO

/* Clears the staging tables so a run always starts from a clean slate, even after a failure. */
CREATE PROCEDURE etl.usp_StartRestaurantSync
WITH EXECUTE AS OWNER
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE stg.Restaurant;
	TRUNCATE TABLE stg.RestaurantKey;

	UPDATE dbo.WatermarkControl
		SET LastSyncStartDateTime = SYSUTCDATETIME()
	WHERE TableName = N'demo.Restaurant';
END;
GO

/* =====================================================================================
   Applies the staged delta to the target table in a single transaction:

	 1. INSERT rows that are new.
	 2. UPDATE rows whose non-key column values actually changed.
	 3. DELETE rows that no longer exist at the source.
	 4. Advance the watermark.

   @ExpectedKeyCount is the source row count reported by the API at the start of the run.
   If the staged key set does not match it, the key harvest was incomplete and the whole run is
   aborted so an interrupted run can never wipe the target table.

   @ExpectedDeltaCount is the number of rows the API reported inside the watermark window, and
   guards the delta half the same way. Both guards deliberately fail the run rather than applying
   a partial result: the watermark only advances on a complete load, so a failure is always
   recoverable by simply running again.

   The new watermark is deliberately NOT passed in as a parameter. Azure Data Factory coerces any
   stored procedure argument that looks like a timestamp through a DateTime and re-formats it at
   whole-second precision - even when the parameter is declared as a string. That silently dropped
   the millisecond component and made every subsequent run re-read the newest row.

   Instead the watermark is derived from the rows that were actually staged, which travel through
   the Copy activity's column mapping and keep full precision. The delta window was
   (old, pinned upper bound], so the staged rows contain every change in that window and
   MAX(LastUpdatedDateTime) over them is the correct - and safest - new low bound. When nothing
   was staged the watermark simply stays where it was.
   ===================================================================================== */
CREATE PROCEDURE etl.usp_ApplyRestaurantSync
	@ExpectedKeyCount   INT,
	@ExpectedDeltaCount INT = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
	SET NOCOUNT ON;
	SET XACT_ABORT ON;

	DECLARE @watermark DATETIME2(3) =
		(SELECT MAX(w.Value)
		 FROM (VALUES
				((SELECT WatermarkValue FROM dbo.WatermarkControl WHERE TableName = N'demo.Restaurant')),
				((SELECT MAX(LastUpdatedDateTime) FROM stg.Restaurant))
			  ) AS w(Value));

	DECLARE @mergeActions TABLE (MergeAction NVARCHAR(10) NOT NULL);

	/* Both counts are DISTINCT and non-NULL on purpose, and each half matters for a different
	   reason. Every Copy activity has a retry policy, and a retry that happens after rows were
	   already committed leaves duplicates in staging; the merge and the delete are both set-based
	   and already tolerate that, so counting raw rows would be the only thing in the procedure
	   that fails a run purely because a page was retried. The staging key column is also
	   deliberately nullable so a malformed page lands as NULL instead of failing the copy - and a
	   raw count would count those NULLs toward the expected total, letting an incomplete key
	   harvest pass this guard and then delete live rows. */
	DECLARE @inserted INT = 0,
			@updated  INT = 0,
			@deleted  INT = 0,
			@stagedKeyCount   INT = (SELECT COUNT_BIG(DISTINCT RestaurantId) FROM stg.RestaurantKey WHERE RestaurantId IS NOT NULL),
			@stagedDeltaCount INT = (SELECT COUNT_BIG(DISTINCT RestaurantId) FROM stg.Restaurant WHERE RestaurantId IS NOT NULL);

	IF @ExpectedKeyCount IS NOT NULL AND @stagedKeyCount <> @ExpectedKeyCount
	BEGIN
		DECLARE @message NVARCHAR(400) =
			CONCAT(N'Key reconciliation aborted: staged ', @stagedKeyCount,
					   N' distinct key(s) but the source reported ', @ExpectedKeyCount,
				   N'. Stale rows will not be deleted this run.');
		THROW 50001, @message, 1;
	END

	/* The same guard for the delta half. Without it a GraphQL error - which is returned with
	   HTTP 200, so the Copy activity still "succeeds" but stages no rows - would look like a
	   short page, end the paging loop early, merge a partial delta and still advance the
	   watermark. Rows missed that way are never revisited, because the watermark moves past
	   them. Failing here instead leaves the watermark untouched so the next run retries. */
	IF @ExpectedDeltaCount IS NOT NULL AND @stagedDeltaCount <> @ExpectedDeltaCount
	BEGIN
		DECLARE @deltaMessage NVARCHAR(400) =
			CONCAT(N'Delta load aborted: staged ', @stagedDeltaCount,
				   N' distinct row(s) but the source reported ', @ExpectedDeltaCount,
				   N' in the watermark window. The watermark will not advance this run.');
		THROW 50003, @deltaMessage, 1;
	END

	BEGIN TRANSACTION;

	/* The delta window can only contain one row per key, but a retried page could have been
	   staged twice, so collapse staging to one row per key before merging. */
	WITH DeltaSource AS
	(
		SELECT
			s.RestaurantId,
			s.Name,
			s.Borough,
			s.Cuisine,
			s.InspectionGrade,
			s.InspectionScore,
			s.SeatingCapacity,
			s.IsActive,
			s.CreateDateTime,
			s.LastUpdatedDateTime,
			RowRank = ROW_NUMBER() OVER (PARTITION BY s.RestaurantId ORDER BY s.LastUpdatedDateTime DESC)
		FROM stg.Restaurant AS s
		WHERE s.RestaurantId IS NOT NULL
	)
	MERGE dbo.Restaurant WITH (HOLDLOCK) AS t
	USING (SELECT * FROM DeltaSource WHERE RowRank = 1) AS s
		ON t.RestaurantId = s.RestaurantId

	WHEN MATCHED AND EXISTS
		(
			/* EXCEPT compares NULLs correctly, so the row is only touched when it really changed. */
			SELECT s.Name, s.Borough, s.Cuisine, s.InspectionGrade, s.InspectionScore,
				   s.SeatingCapacity, s.IsActive, s.CreateDateTime, s.LastUpdatedDateTime
			EXCEPT
			SELECT t.Name, t.Borough, t.Cuisine, t.InspectionGrade, t.InspectionScore,
				   t.SeatingCapacity, t.IsActive, t.CreateDateTime, t.LastUpdatedDateTime
		)
	THEN UPDATE SET
			t.Name                = s.Name,
			t.Borough             = s.Borough,
			t.Cuisine             = s.Cuisine,
			t.InspectionGrade     = s.InspectionGrade,
			t.InspectionScore     = s.InspectionScore,
			t.SeatingCapacity     = s.SeatingCapacity,
			t.IsActive            = s.IsActive,
			t.CreateDateTime      = s.CreateDateTime,
			t.LastUpdatedDateTime = s.LastUpdatedDateTime,
			t.SyncUpdatedDateTime = SYSUTCDATETIME()

	WHEN NOT MATCHED BY TARGET
	THEN INSERT (RestaurantId, Name, Borough, Cuisine, InspectionGrade, InspectionScore,
				 SeatingCapacity, IsActive, CreateDateTime, LastUpdatedDateTime,
				 SyncInsertedDateTime, SyncUpdatedDateTime)
		 VALUES (s.RestaurantId, s.Name, s.Borough, s.Cuisine, s.InspectionGrade, s.InspectionScore,
				 s.SeatingCapacity, s.IsActive, s.CreateDateTime, s.LastUpdatedDateTime,
				 SYSUTCDATETIME(), SYSUTCDATETIME())

	OUTPUT $action INTO @mergeActions(MergeAction);

	SELECT
		@inserted = SUM(CASE WHEN MergeAction = 'INSERT' THEN 1 ELSE 0 END),
		@updated  = SUM(CASE WHEN MergeAction = 'UPDATE' THEN 1 ELSE 0 END)
	FROM @mergeActions;

	/* Deletes can never appear in a watermark delta, so they are found by reconciling the
	   target against the full key set harvested from the source in this same run. */
	IF @ExpectedKeyCount IS NOT NULL
	BEGIN
		DELETE t
		FROM dbo.Restaurant AS t
		WHERE NOT EXISTS (SELECT 1 FROM stg.RestaurantKey AS k WHERE k.RestaurantId = t.RestaurantId);

		SET @deleted = @@ROWCOUNT;
	END

	UPDATE dbo.WatermarkControl
		SET WatermarkValue      = @watermark,
			LastSyncEndDateTime = SYSUTCDATETIME(),
			LastRowsInserted    = ISNULL(@inserted, 0),
			LastRowsUpdated     = ISNULL(@updated, 0),
			LastRowsDeleted     = @deleted
	WHERE TableName = N'demo.Restaurant';

	COMMIT TRANSACTION;

	SELECT
		RowsInserted   = ISNULL(@inserted, 0),
		RowsUpdated    = ISNULL(@updated, 0),
		RowsDeleted    = @deleted,
		NewWatermark   = FORMAT(@watermark, 'yyyy-MM-ddTHH:mm:ss.fff', 'en-US'),
		TargetRowCount = (SELECT COUNT_BIG(1) FROM dbo.Restaurant);
END;
GO

/* Test helper: empties the target and rewinds the watermark so the next run is a full load. */
CREATE PROCEDURE etl.usp_ResetRestaurantTarget
WITH EXECUTE AS OWNER
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.Restaurant;
	TRUNCATE TABLE stg.Restaurant;
	TRUNCATE TABLE stg.RestaurantKey;

	UPDATE dbo.WatermarkControl
		SET WatermarkValue        = '1900-01-01T00:00:00.000',
			LastSyncStartDateTime = NULL,
			LastSyncEndDateTime   = NULL,
			LastRowsInserted      = NULL,
			LastRowsUpdated       = NULL,
			LastRowsDeleted       = NULL
	WHERE TableName = N'demo.Restaurant';
END;
GO

SELECT TableName, WatermarkValue FROM dbo.WatermarkControl;
GO
