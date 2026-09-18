/* =====================================================================================
   Source database: nyc-dohmh-adf-graphql-to-sql-1

   Grants the REST API App Service system-assigned managed identity (SAMI) read access.

   The user is created WITH SID / TYPE = E instead of FROM EXTERNAL PROVIDER so the script
   does not depend on the logical server being able to call Microsoft Graph.

   IMPORTANT: for a service principal (which is what a managed identity is), Azure SQL matches
   the incoming token on the identity's APPLICATION / CLIENT ID - not its object ID. Using the
   object ID produces "Login failed for user '<token-identified principal>'".

   App Service    : nyc-dohmh-adf-graphql-to-sql
   SAMI object ID : 5163fa70-898c-4a74-938e-1e343b94ad25   (not used here)
   SAMI client ID : 85455e94-9487-4d4e-a57d-994fb35d4166   (this is the SID)

   Run as a Microsoft Entra administrator of the logical server.
   ===================================================================================== */

SET NOCOUNT ON;
GO

DECLARE @principalName SYSNAME       = N'nyc-dohmh-adf-graphql-to-sql';
DECLARE @clientId      NVARCHAR(50)  = N'85455e94-9487-4d4e-a57d-994fb35d4166';
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

/* "Read data" permissions. db_datareader grants SELECT across the whole database.
   For tighter least-privilege you can replace the role membership with:
	   GRANT SELECT ON SCHEMA::demo TO [nyc-dohmh-adf-graphql-to-sql]; */
SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@principalName) + N';';
EXEC sys.sp_executesql @sql;

PRINT 'Granted db_datareader to ' + @principalName + '.';
GO

SELECT
	UserName       = dp.name,
	UserType       = dp.type_desc,
	ClientId       = CONVERT(UNIQUEIDENTIFIER, dp.sid),
	RoleMembership = r.name
FROM sys.database_principals AS dp
LEFT JOIN sys.database_role_members AS drm ON drm.member_principal_id = dp.principal_id
LEFT JOIN sys.database_principals  AS r    ON r.principal_id = drm.role_principal_id
WHERE dp.name = N'nyc-dohmh-adf-graphql-to-sql';
GO
