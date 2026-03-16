using System.Net;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Parquet;
using Parquet.Data;
using Parquet.Schema;

namespace ZipCsvFunction;

public class ZipCsv
{
    private static readonly DataField[] Fields =
    [
        new DataField<string?>("ProductId"),
        new DataField<string?>("Luma"),
        new DataField<string?>("Workspace"),
        new DataField<string?>("DeploymentName"),
        new DataField<string?>("ModelName"),
        new DataField<string?>("AccountName"),
        new DataField<string?>("SubscriptionId"),
        new DataField<string?>("ResourceID"),
        new DataField<string?>("SkuName"),
        new DataField<long?>("SkuCapacity"),
        new DataField<string?>("BackendId"),
        new DataField<string?>("Endpoint"),
        new DataField<long?>("PromptTokens"),
        new DataField<long?>("CompletionTokens"),
        new DataField<long?>("TotalTokens"),
        new DataField<long?>("Calls"),
        new DataField<DateTime?>("FirstSeen"),
        new DataField<DateTime?>("LastSeen"),
        new DataField<string?>("Regions"),
        new DataField<string?>("CallerIpAddresses")
    ];

    private static readonly ParquetSchema Schema = new(Fields);

    [Function("ZipCsv")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = null)] HttpRequestData req)
    {
        using var reader = new StreamReader(req.Body);
        var json = await reader.ReadToEndAsync();

        var rows = JsonSerializer.Deserialize<List<Dictionary<string, JsonElement>>>(json) ?? [];

        var filename = req.Query["filename"] is { Length: > 0 } f
            ? Path.GetFileNameWithoutExtension(f) + ".parquet"
            : "chargeBack-daily.parquet";

        using var ms = new MemoryStream();
        using (var writer = await ParquetWriter.CreateAsync(Schema, ms))
        {
            using var rg = writer.CreateRowGroup();

            await rg.WriteColumnAsync(new DataColumn(Fields[0],  rows.Select(r => Str(r, "ProductId")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[1],  rows.Select(r => Str(r, "Luma")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[2],  rows.Select(r => Str(r, "Workspace")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[3],  rows.Select(r => Str(r, "DeploymentName")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[4],  rows.Select(r => Str(r, "ModelName")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[5],  rows.Select(r => Str(r, "AccountName")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[6],  rows.Select(r => Str(r, "SubscriptionId")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[7],  rows.Select(r => Str(r, "ResourceID")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[8],  rows.Select(r => Str(r, "SkuName")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[9],  rows.Select(r => Long(r, "SkuCapacity")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[10], rows.Select(r => Str(r, "BackendId")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[11], rows.Select(r => Str(r, "Endpoint")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[12], rows.Select(r => Long(r, "PromptTokens")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[13], rows.Select(r => Long(r, "CompletionTokens")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[14], rows.Select(r => Long(r, "TotalTokens")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[15], rows.Select(r => Long(r, "Calls")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[16], rows.Select(r => Dt(r, "FirstSeen")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[17], rows.Select(r => Dt(r, "LastSeen")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[18], rows.Select(r => Str(r, "Regions")).ToArray()));
            await rg.WriteColumnAsync(new DataColumn(Fields[19], rows.Select(r => Str(r, "CallerIpAddresses")).ToArray()));
        }

        ms.Position = 0;
        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/octet-stream");
        response.Headers.Add("Content-Disposition", $"attachment; filename=\"{filename}\"");
        await ms.CopyToAsync(response.Body);
        return response;
    }

    private static string? Str(Dictionary<string, JsonElement> row, string key) =>
        row.TryGetValue(key, out var v) && v.ValueKind != JsonValueKind.Null ? v.GetString() : null;

    private static long? Long(Dictionary<string, JsonElement> row, string key)
    {
        if (!row.TryGetValue(key, out var v) || v.ValueKind == JsonValueKind.Null) return null;
        return v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;
    }

    private static DateTime? Dt(Dictionary<string, JsonElement> row, string key)
    {
        if (!row.TryGetValue(key, out var v) || v.ValueKind == JsonValueKind.Null) return null;
        var s = v.GetString();
        return s is not null && DateTimeOffset.TryParse(s, out var dto) ? dto.UtcDateTime : null;
    }
}
