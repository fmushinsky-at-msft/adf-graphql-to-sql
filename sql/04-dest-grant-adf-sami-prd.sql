/* =====================================================================================
   Destination database: nyc-dohmh-adf-graphql-to-sql-prd-2   (PRODUCTION)

   Grants the PRODUCTION Azure Data Factory system-assigned managed identity (SAMI) the
   read-write access it needs to land staged pages and apply the merge.

   Same grants as 04-dest-grant-adf-sami.sql. Every factory has its own SAMI, and the CI/CD
   workflow never deploys the factory resource itself, so each environment's database needs a
   one-time grant for that environment's factory. Run 03-dest-schema.sql against this database
   first.

   IMPORTANT: for a service principal (which is what a managed identity is), Azure SQL matches
   the incoming token on the identity's APPLICATION / CLIENT ID - not its object ID. Using the
   object ID produces "Login failed for user '<token-identified principal>'".

   Data factory    : nyc-dohmh-adf-graphql-to-sql-prd
   SAMI object ID  : f0d636c6-4bb4-415a-b473-771b0b905374   (not used here)
   SAMI client ID  : db7e1054-9554-4701-937f-6294e7ccb9ed   (this is the SID)

   Run as a Microsoft Entra administrator of the logical server.
   ===================================================================================== */

SET NOCOUNT ON;
GO

DECLARE @principalName SYSNAME       = N'nyc-dohmh-adf-graphql-to-sql-prd-adf';
DECLARE @clientId      NVARCHAR(50)  = N'db7e1054-9554-4701-937f-6294e7ccb9ed';
DECLARE @sid           VARBINARY(16) = CAST(CAST(@clientId AS UNIQUEIDENTIFIER) AS VARBINARY(16));
DECLARE @sql           NVARCHAR(MAX);

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @principalName)
BEGIN
	SET @sql = N'DROP USER ' + QUOTENAME(@principalName) + N';';
	EXEC sys.sp_executesql @sql;
END

SET @sql = N'CREATE USER ' + QUOTENAME(@principalName)
		 + N' WITH SID = ' + CONVERT(NVARCHAR(100), @sid, 1)
		 + N', TYPE = E;';
EXEC sys.sp_executesql @sql;

/* Read access: the pipeline looks up the stored watermark.
   Write access: Copy activities bulk-insert each page into the stg tables. */
SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@principalName) + N';';
EXEC sys.sp_executesql @sql;

SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@principalName) + N';';
EXEC sys.sp_executesql @sql;

/* The ETL procedures run WITH EXECUTE AS OWNER, so EXECUTE on the etl schema is all that is
   needed - the factory identity never needs ALTER (TRUNCATE) or DELETE rights of its own. */
SET @sql = N'GRANT EXECUTE ON SCHEMA::etl TO ' + QUOTENAME(@principalName) + N';';
EXEC sys.sp_executesql @sql;

PRINT 'Granted db_datareader, db_datawriter and EXECUTE ON SCHEMA::etl to ' + @principalName + '.';
GO

SELECT
	UserName       = dp.name,
	UserType       = dp.type_desc,
	ClientId       = CONVERT(UNIQUEIDENTIFIER, dp.sid),
	RoleMembership = r.name
FROM sys.database_principals AS dp
LEFT JOIN sys.database_role_members AS drm ON drm.member_principal_id = dp.principal_id
LEFT JOIN sys.database_principals  AS r    ON r.principal_id = drm.role_principal_id
WHERE dp.name = N'nyc-dohmh-adf-graphql-to-sql-prd-adf';

SELECT
	GrantedOn  = CONCAT(SCHEMA_NAME(p.major_id), ' (schema)'),
	Permission = p.permission_name,
	State      = p.state_desc
FROM sys.database_permissions AS p
INNER JOIN sys.database_principals AS dp ON dp.principal_id = p.grantee_principal_id
WHERE dp.name = N'nyc-dohmh-adf-graphql-to-sql-prd-adf'
  AND p.class_desc = 'SCHEMA';
GO
