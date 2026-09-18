/* =====================================================================================
   Source database: nyc-dohmh-adf-graphql-to-sql-1
   Creates the sample table that the GraphQL API serves, and loads sample data.

   The table intentionally has:
	 * a single-column primary key            -> RestaurantId
	 * audit columns                          -> CreateDateTime / LastUpdatedDateTime
	 * a trigger that maintains LastUpdatedDateTime so watermark deltas are reliable

   This script is idempotent - re-running it recreates the table and reloads the data.
   ===================================================================================== */

SET NOCOUNT ON;
GO

IF SCHEMA_ID('demo') IS NULL
	EXEC ('CREATE SCHEMA demo AUTHORIZATION dbo;');
GO

DROP TABLE IF EXISTS demo.Restaurant;
GO

CREATE TABLE demo.Restaurant
(
	RestaurantId        INT            NOT NULL,
	Name                NVARCHAR(200)  NOT NULL,
	Borough             NVARCHAR(50)   NOT NULL,
	Cuisine             NVARCHAR(100)  NOT NULL,
	InspectionGrade     CHAR(1)        NULL,
	InspectionScore     INT            NULL,
	SeatingCapacity     INT            NOT NULL,
	IsActive            BIT            NOT NULL CONSTRAINT DF_Restaurant_IsActive DEFAULT (1),
	CreateDateTime      DATETIME2(3)   NOT NULL CONSTRAINT DF_Restaurant_CreateDateTime DEFAULT (SYSUTCDATETIME()),
	LastUpdatedDateTime DATETIME2(3)   NOT NULL CONSTRAINT DF_Restaurant_LastUpdatedDateTime DEFAULT (SYSUTCDATETIME()),
	CONSTRAINT PK_Restaurant PRIMARY KEY CLUSTERED (RestaurantId)
);
GO

/* The GraphQL API filters and orders by LastUpdatedDateTime for watermark-based delta reads. */
CREATE NONCLUSTERED INDEX IX_Restaurant_LastUpdatedDateTime
	ON demo.Restaurant (LastUpdatedDateTime, RestaurantId);
GO

/* Keeps LastUpdatedDateTime accurate no matter who updates the row, which is what makes the
   incremental (watermark) load in Azure Data Factory correct. */
CREATE TRIGGER demo.TR_Restaurant_SetLastUpdatedDateTime
	ON demo.Restaurant
	AFTER UPDATE
AS
BEGIN
	SET NOCOUNT ON;

	IF NOT EXISTS (SELECT 1 FROM inserted)
		RETURN;

	UPDATE r
		SET r.LastUpdatedDateTime = SYSUTCDATETIME()
	FROM demo.Restaurant AS r
	INNER JOIN inserted AS i ON i.RestaurantId = r.RestaurantId;
END;
GO

/* -------------------------------------------------------------------------------------
   Sample data: 75 rows.
   Timestamps are spread over the previous 30 days so the first watermark load has a
   realistic distribution rather than every row sharing one timestamp.
   ------------------------------------------------------------------------------------- */
DISABLE TRIGGER demo.TR_Restaurant_SetLastUpdatedDateTime ON demo.Restaurant;
GO

INSERT INTO demo.Restaurant
	(RestaurantId, Name, Borough, Cuisine, InspectionGrade, InspectionScore, SeatingCapacity)
VALUES
	( 1, N'Katz''s Delicatessen',        N'Manhattan',     N'Delicatessen',  'A', 11, 250),
	( 2, N'Peter Luger Steak House',     N'Brooklyn',      N'Steakhouse',    'A',  9, 180),
	( 3, N'Di Fara Pizza',               N'Brooklyn',      N'Pizza',         'B', 18,  40),
	( 4, N'Gray''s Papaya',              N'Manhattan',     N'Hot Dogs',      'A', 12,  15),
	( 5, N'Jackson Diner',               N'Queens',        N'Indian',        'A', 10, 120),
	( 6, N'Arthur Avenue Trattoria',     N'Bronx',         N'Italian',       'A',  8,  95),
	( 7, N'Enoteca Maria',               N'Staten Island', N'Italian',       'A',  7,  45),
	( 8, N'Joe''s Shanghai',             N'Manhattan',     N'Chinese',       'B', 21, 110),
	( 9, N'Totonno''s Pizzeria',         N'Brooklyn',      N'Pizza',         'A', 13,  60),
	(10, N'The Lemon Ice King of Corona',N'Queens',        N'Desserts',      'A',  5,  10),
	(11, N'Sylvia''s Restaurant',        N'Manhattan',     N'Soul Food',     'A', 12, 200),
	(12, N'Roberta''s',                  N'Brooklyn',      N'Pizza',         'A',  9, 140),
	(13, N'Taverna Kyclades',            N'Queens',        N'Greek',         'A', 11,  85),
	(14, N'Zero Otto Nove',              N'Bronx',         N'Italian',       'A', 10, 130),
	(15, N'Denino''s Pizzeria',          N'Staten Island', N'Pizza',         'A', 14,  90),
	(16, N'Russ & Daughters Cafe',       N'Manhattan',     N'Delicatessen',  'A',  6,  70),
	(17, N'Lucali',                      N'Brooklyn',      N'Pizza',         'A',  8,  50),
	(18, N'Nan Xiang Xiao Long Bao',     N'Queens',        N'Chinese',       'B', 19,  75),
	(19, N'Charlie''s Bar & Kitchen',    N'Staten Island', N'American',      'A', 11, 100),
	(20, N'Liebman''s Deli',             N'Bronx',         N'Delicatessen',  'A', 12,  55),
	(21, N'Xi''an Famous Foods',         N'Manhattan',     N'Chinese',       'A', 13,  35),
	(22, N'Juniors Restaurant',          N'Brooklyn',      N'American',      'A', 10, 300),
	(23, N'Bahari Estiatorio',           N'Queens',        N'Greek',         'A',  9,  80),
	(24, N'Emilia''s Restaurant',        N'Bronx',         N'Italian',       'B', 17,  65),
	(25, N'Bayou Restaurant',            N'Staten Island', N'Cajun',         'A', 12,  70),
	(26, N'Le Bernardin',                N'Manhattan',     N'French',        'A',  4, 120),
	(27, N'Olmsted',                     N'Brooklyn',      N'American',      'A',  7,  60),
	(28, N'Casa Enrique',                N'Queens',        N'Mexican',       'A',  8,  55),
	(29, N'Beatstro',                    N'Bronx',         N'American',      'A', 11,  90),
	(30, N'Lakruwana',                   N'Staten Island', N'Sri Lankan',    'A', 10,  60),
	(31, N'Gramercy Tavern',             N'Manhattan',     N'American',      'A',  5, 150),
	(32, N'Llama Inn',                   N'Brooklyn',      N'Peruvian',      'A',  9,  85),
	(33, N'Adda Indian Canteen',         N'Queens',        N'Indian',        'A', 12,  50),
	(34, N'Travesias',                   N'Bronx',         N'Latin',         'B', 20,  70),
	(35, N'Ruddy & Dean',                N'Staten Island', N'Steakhouse',    'A',  8, 110),
	(36, N'Momofuku Noodle Bar',         N'Manhattan',     N'Japanese',      'A', 10,  65),
	(37, N'Lilia',                       N'Brooklyn',      N'Italian',       'A',  6,  95),
	(38, N'SriPraPhai',                  N'Queens',        N'Thai',          'A', 13, 120),
	(39, N'Havana Cafe',                 N'Bronx',         N'Cuban',         'A', 11, 100),
	(40, N'Vida',                        N'Staten Island', N'American',      'A',  9,  65),
	(41, N'Balthazar',                   N'Manhattan',     N'French',        'A', 12, 175),
	(42, N'Four Horsemen',               N'Brooklyn',      N'American',      'A',  7,  55),
	(43, N'Ayada Thai',                  N'Queens',        N'Thai',          'A', 10,  60),
	(44, N'Estrellita Poblana',          N'Bronx',         N'Mexican',       'B', 16,  45),
	(45, N'Pier 76',                     N'Staten Island', N'Italian',       'A', 13,  85),
	(46, N'Via Carota',                  N'Manhattan',     N'Italian',       'A',  8,  70),
	(47, N'Win Son',                     N'Brooklyn',      N'Taiwanese',     'A', 11,  50),
	(48, N'Tortilleria Nixtamal',        N'Queens',        N'Mexican',       'A', 12,  40),
	(49, N'Ceetay',                      N'Bronx',         N'Japanese',      'A',  9,  75),
	(50, N'Beso',                        N'Staten Island', N'Spanish',       'A', 10,  80),
	(51, N'Superiority Burger',          N'Manhattan',     N'Vegetarian',    'A',  6,  30),
	(52, N'Chez Ma Tante',               N'Brooklyn',      N'American',      'A',  9,  45),
	(53, N'Little Pepper',               N'Queens',        N'Chinese',       'B', 18,  55),
	(54, N'Antonio''s Trattoria',        N'Bronx',         N'Italian',       'A', 10,  70),
	(55, N'Angelina''s Ristorante',      N'Staten Island', N'Italian',       'A',  7, 220),
	(56, N'Dhamaka',                     N'Manhattan',     N'Indian',        'A',  8,  60),
	(57, N'Aunts et Uncles',             N'Brooklyn',      N'Vegan',         'A',  5,  35),
	(58, N'Hahm Ji Bach',                N'Queens',        N'Korean',        'A', 12, 140),
	(59, N'Charlie''s Bar',              N'Bronx',         N'American',      'B', 22,  60),
	(60, N'San Rasa',                    N'Staten Island', N'Sri Lankan',    'A', 11,  55),
	(61, N'Wu''s Wonton King',           N'Manhattan',     N'Chinese',       'B', 19,  90),
	(62, N'Rucola',                      N'Brooklyn',      N'Italian',       'A',  8,  65),
	(63, N'Mango Mango Dessert',         N'Queens',        N'Desserts',      'A',  6,  30),
	(64, N'Mottley Kitchen',             N'Bronx',         N'Cafe',          'A',  9,  40),
	(65, N'Richmond Republic',           N'Staten Island', N'American',      'A', 13,  95),
	(66, N'Frenchette',                  N'Manhattan',     N'French',        'A',  7, 105),
	(67, N'Fausto',                      N'Brooklyn',      N'Italian',       'A',  6,  70),
	(68, N'Kabab Cafe',                  N'Queens',        N'Egyptian',      'B', 17,  25),
	(69, N'Tin Marin',                   N'Bronx',         N'Salvadoran',    'A', 12,  50),
	(70, N'Mario''s Trattoria',          N'Staten Island', N'Italian',       'A', 10,  75),
	(71, N'Cafe Katja',                  N'Manhattan',     N'Austrian',      'A',  8,  40),
	(72, N'Sunday in Brooklyn',          N'Brooklyn',      N'American',      'A',  9, 120),
	(73, N'Zabb Elee',                   N'Queens',        N'Thai',          'A', 11,  45),
	(74, N'Tribeca Taphouse',            N'Bronx',         N'American',      'A', 14,  85),
	(75, N'Bocelli Ristorante',          N'Staten Island', N'Italian',       'A',  7, 130);
GO

/* Spread the audit timestamps across the last 30 days for a realistic starting point. */
UPDATE demo.Restaurant
	SET CreateDateTime      = DATEADD(MINUTE, -1 * (RestaurantId * 577 % 43200) - 43200, SYSUTCDATETIME()),
		LastUpdatedDateTime = DATEADD(MINUTE, -1 * (RestaurantId * 331 % 43200),         SYSUTCDATETIME());
GO

UPDATE demo.Restaurant
	SET LastUpdatedDateTime = CreateDateTime
WHERE LastUpdatedDateTime < CreateDateTime;
GO

ENABLE TRIGGER demo.TR_Restaurant_SetLastUpdatedDateTime ON demo.Restaurant;
GO

SELECT
	RowCountTotal    = COUNT(*),
	MinCreated       = MIN(CreateDateTime),
	MaxLastUpdated   = MAX(LastUpdatedDateTime)
FROM demo.Restaurant;
GO
