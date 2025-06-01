using Microsoft.AspNetCore.Mvc;
using Npgsql;
using System.Text.Json;
using System.Text.Json.Serialization;

using Dapper;

[module: DapperAot]
var builder = WebApplication.CreateSlimBuilder(args);

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonSerializerContext.Default);
});
const string CONNECTION_STRING = "Host=127.0.0.1;Database=sbtest;Username=sbtest;Password=password";
builder.Services.AddSingleton<NpgsqlDataSource>(_ =>
{
    var dataSourceBuilder = new NpgsqlDataSourceBuilder(CONNECTION_STRING);
    return dataSourceBuilder.Build();
});

var app = builder.Build();



app.MapPost("/postgres/cache", async ([FromBody] CacheItem cacheItem, NpgsqlDataSource dataSource) =>
{
    using var connection = await dataSource.OpenConnectionAsync();

    await connection.ExecuteAsync(
        """
        INSERT INTO cache(key, value)
        VALUES (@Key, @Value::jsonb)
        ON CONFLICT (key) DO UPDATE
        SET value = excluded.value;
        """,
        new { cacheItem.Key, Value = cacheItem.Value.ToString() });

    return Results.Ok();
});

app.MapGet("/postgres/cache/{key}", async (string key, NpgsqlDataSource dataSource) =>
{
    using var connection = await dataSource.OpenConnectionAsync();

    var value = await connection.QuerySingleOrDefaultAsync<string>(
        "SELECT value FROM cache WHERE key = @Key",
        new { Key = key });

    return value is not null ?
        Results.Ok(JsonDocument.Parse(value).RootElement) :
        Results.NotFound();
});

app.MapDelete("/postgres/cache", async (NpgsqlDataSource dataSource) =>
{
    using var connection = await dataSource.OpenConnectionAsync();
    await connection.ExecuteAsync("DELETE FROM cache");
    return Results.Ok();
});

app.Run();

[JsonSerializable(typeof(CacheItem))]
internal partial class AppJsonSerializerContext : JsonSerializerContext
{

}

// Add the CacheItem record definition
public record CacheItem(string Key, JsonElement Value);
