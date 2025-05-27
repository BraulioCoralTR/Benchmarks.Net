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


var app = builder.Build();

const string CONNECTION_STRING = "Host=127.0.0.1;Database=sbtest;Username=sbtest;Password=password";

app.MapPost("/postgres/cache", async ([FromBody] CacheItem cacheItem) =>
{
    using var connection = new NpgsqlConnection(CONNECTION_STRING);

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

app.MapGet("/postgres/cache/{key}", async (string key) =>
{
    using var connection = new NpgsqlConnection(CONNECTION_STRING);

    var value = await connection.QuerySingleOrDefaultAsync<string>(
        "SELECT value FROM cache WHERE key = @Key",
        new { Key = key });

    return value is not null ?
        Results.Ok(JsonDocument.Parse(value).RootElement) :
        Results.NotFound();
});

app.Run();

[JsonSerializable(typeof(CacheItem))]
internal partial class AppJsonSerializerContext : JsonSerializerContext
{

}

// Add the CacheItem record definition
public record CacheItem(string Key, JsonElement Value);
