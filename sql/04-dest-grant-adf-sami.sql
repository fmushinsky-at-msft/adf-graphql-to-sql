/* =====================================================================================
   Destination database: nyc-dohmh-adf-graphql-to-sql-2

   Grants the Azure Data Factory system-assigned managed identity (SAMI) the read-write
   access it needs to land staged pages and apply the merge.

   IMPORTANT: for a service principal (which is what a managed identity is), Azure SQL matches
   the incoming token on the identity's APPLICATION / CLIENT ID - not its object ID. Using the
   object ID produces "Login failed for user '<token-identified principal>'".

   Data factory    : nyc-dohmh-adf-graphql-to-sql
   SAMI object ID  : 8686c50d-ca5f-4e1c-9695-cb7d9545746f   (not used here)
   SAMI client ID  : 202f8463-3cbc-498e-8495-44cc8a09d6d7   (this is the SID)

   Run as a Microsoft Entra administrator of the logical server.
   ===================================================================================== */

SET NOCOUNT ON;
GO

DECLARE @principalName SYSNAME       = N'nyc-dohmh-adf-graphql-to-sql-adf';
DECLARE @clientId      NVARCHAR(50)  = N'202f8463-3cbc-498e-8495-44cc8a09d6d7';
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
WHERE dp.name = N'nyc-dohmh-adf-graphql-to-sql-adf';

SELECT
	GrantedOn  = CONCAT(SCHEMA_NAME(p.major_id), ' (schema)'),
	Permission = p.permission_name,
	State      = p.state_desc
FROM sys.database_permissions AS p
INNER JOIN sys.database_principals AS dp ON dp.principal_id = p.grantee_principal_id
WHERE dp.name = N'nyc-dohmh-adf-graphql-to-sql-adf'
  AND p.class_desc = 'SCHEMA';
GO
