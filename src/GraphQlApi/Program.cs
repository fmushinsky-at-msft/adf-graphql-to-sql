using NycDohmh.GraphQlApi.Data;
using NycDohmh.GraphQlApi.GraphQL;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddSingleton<RestaurantRepository>();

// The source data is public reference data, so introspection stays on and the schema is
// browsable. Every resolver is read-only; there is no mutation or subscription type.
// Cost limits are disabled because Azure Data Factory requests whole pages in one query.
builder.Services
    .AddGraphQLServer()
    .AddQueryType<Query>()
    // HotChocolate turns introspection off outside Development. This is a read-only sample over
    // public reference data, so it is turned back on to keep the schema explorable from any client.
    .DisableIntrospection(false)
    // Resolver failures are logged in full by RestaurantRepository. Outside Development the
    // client only sees a generic message so internal details are never exposed to anonymous callers.
    .AddErrorFilter(error => builder.Environment.IsDevelopment() && error.Exception is not null
        ? error.WithMessage(error.Exception.Message)
        : error)
    .ModifyCostOptions(options =>
    {
        options.EnforceCostLimits = false;
    });

var app = builder.Build();

// The GraphQL endpoint is intentionally anonymous - no user authentication is required.
// The API's own access to the source database is authenticated with its system-assigned
// managed identity via the connection string, so no credentials are exposed to callers.
app.MapGraphQL("/graphql");

app.MapGet("/", () => Results.Redirect("/graphql"))
   .ExcludeFromDescription();

app.MapGet("/healthz", () => Results.Ok(new
{
    status = "healthy",
    utc = DateTime.UtcNow.ToString("O")
}));

app.Run();
