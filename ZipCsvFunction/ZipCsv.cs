using System.Globalization;
using System.IO.Compression;
using Azure.Identity;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Parquet;
using Parquet.Data;
using Parquet.Schema;

namespace ZipCsvFunction;

/// <summary>
/// Blob-triggered function that converts CSV files to compressed Parquet format (gzip).
/// Triggered when a CSV blob is created in the reportoutput container.
/// Uses Managed Identity for authentication - no API keys or app registration needed.
/// </summary>
public class CsvToParquet
{
    private readonly ILogger<CsvToParquet> _logger;

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

    // CSV column headers in expected order (must match Logic App output)
    private static readonly string[] ExpectedHeaders =
    [
        "ProductId", "Luma", "Workspace", "DeploymentName", "ModelName",
        "AccountName", "SubscriptionId", "ResourceID", "SkuName", "SkuCapacity",
        "BackendId", "Endpoint", "PromptTokens", "CompletionTokens", "TotalTokens",
        "Calls", "FirstSeen", "LastSeen", "Regions", "CallerIpAddresses"
    ];

    public CsvToParquet(ILogger<CsvToParquet> logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Blob trigger that fires when a CSV file is created in reportoutput container.
    /// Converts the CSV file to Parquet format.
    /// Filter pattern matches: chargeBack-daily-*.csv (excludes chunk files)
    /// </summary>
    [Function("CsvToParquet")]
    public async Task Run(
        [BlobTrigger("reportoutput/chargeBack-daily-{name}.csv", Connection = "ReportStorageConnection")] Stream csvStream,
        string name,
        Uri uri,
        FunctionContext context)
    {
        var blobName = $"chargeBack-daily-{name}.csv";
        _logger.LogInformation("Blob trigger fired for: {BlobName}", blobName);

        try
        {
            // Read CSV content from the input stream
            using var reader = new StreamReader(csvStream);
            var csvContent = await reader.ReadToEndAsync();

            // Parse CSV and convert to rows
            var rows = ParseCsv(csvContent);

            if (rows.Count == 0)
            {
                _logger.LogWarning("CSV file is empty or has no data rows: {BlobName}", blobName);
                return;
            }

            _logger.LogInformation("Parsed {RowCount} rows from CSV", rows.Count);

            // Convert to Parquet
            using var parquetStream = new MemoryStream();
            await WriteParquetAsync(rows, parquetStream);
            parquetStream.Position = 0;

            // Compress with GZip
            using var gzipStream = new MemoryStream();
            await using (var gzip = new GZipStream(gzipStream, CompressionLevel.Optimal, leaveOpen: true))
            {
                await parquetStream.CopyToAsync(gzip);
            }
            gzipStream.Position = 0;

            _logger.LogInformation("Compressed parquet from {OriginalSize} to {CompressedSize} bytes",
                parquetStream.Length, gzipStream.Length);

            // Get storage account URL from the input blob URI
            var storageAccountUrl = $"{uri.Scheme}://{uri.Host}";

            // Use DefaultAzureCredential for Managed Identity authentication
            var credential = new DefaultAzureCredential();
            var blobServiceClient = new BlobServiceClient(new Uri(storageAccountUrl), credential);
            var containerClient = blobServiceClient.GetBlobContainerClient("reportoutput");

            // Upload compressed Parquet file (same name, .parquet.gz extension)
            var parquetBlobName = blobName.Replace(".csv", ".parquet.gz");
            var destBlobClient = containerClient.GetBlobClient(parquetBlobName);

            await destBlobClient.UploadAsync(gzipStream, overwrite: true);

            _logger.LogInformation("Successfully created compressed Parquet file: {ParquetBlobName}", parquetBlobName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to convert CSV to Parquet: {BlobName}", blobName);
            throw; // Re-throw to trigger retry
        }
    }

    /// <summary>
    /// Parse CSV content into a list of dictionaries.
    /// Handles quoted fields and embedded commas.
    /// </summary>
    private List<Dictionary<string, string?>> ParseCsv(string csvContent)
    {
        var rows = new List<Dictionary<string, string?>>();
        var lines = csvContent.Split('\n', StringSplitOptions.RemoveEmptyEntries);

        if (lines.Length < 2)
            return rows;

        // Parse header row
        var headers = ParseCsvLine(lines[0]);

        // Validate headers match expected schema
        if (headers.Length != ExpectedHeaders.Length)
        {
            _logger.LogWarning("CSV header count mismatch. Expected {Expected}, got {Actual}",
                ExpectedHeaders.Length, headers.Length);
        }

        // Parse data rows
        for (var i = 1; i < lines.Length; i++)
        {
            var line = lines[i].Trim();
            if (string.IsNullOrEmpty(line))
                continue;

            var values = ParseCsvLine(line);
            var row = new Dictionary<string, string?>();

            for (var j = 0; j < Math.Min(headers.Length, values.Length); j++)
            {
                row[headers[j].Trim()] = string.IsNullOrEmpty(values[j]) ? null : values[j];
            }

            rows.Add(row);
        }

        return rows;
    }

    /// <summary>
    /// Parse a single CSV line, handling quoted fields.
    /// </summary>
    private static string[] ParseCsvLine(string line)
    {
        var values = new List<string>();
        var currentValue = "";
        var inQuotes = false;

        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];

            if (c == '"')
            {
                if (inQuotes && i + 1 < line.Length && line[i + 1] == '"')
                {
                    // Escaped quote
                    currentValue += '"';
                    i++;
                }
                else
                {
                    inQuotes = !inQuotes;
                }
            }
            else if (c == ',' && !inQuotes)
            {
                values.Add(currentValue);
                currentValue = "";
            }
            else if (c != '\r') // Skip carriage return
            {
                currentValue += c;
            }
        }

        values.Add(currentValue);
        return values.ToArray();
    }

    /// <summary>
    /// Write parsed rows to a Parquet stream.
    /// </summary>
    private async Task WriteParquetAsync(List<Dictionary<string, string?>> rows, MemoryStream stream)
    {
        using var writer = await ParquetWriter.CreateAsync(Schema, stream);
        using var rg = writer.CreateRowGroup();

        await rg.WriteColumnAsync(new DataColumn(Fields[0], rows.Select(r => Str(r, "ProductId")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[1], rows.Select(r => Str(r, "Luma")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[2], rows.Select(r => Str(r, "Workspace")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[3], rows.Select(r => Str(r, "DeploymentName")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[4], rows.Select(r => Str(r, "ModelName")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[5], rows.Select(r => Str(r, "AccountName")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[6], rows.Select(r => Str(r, "SubscriptionId")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[7], rows.Select(r => Str(r, "ResourceID")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[8], rows.Select(r => Str(r, "SkuName")).ToArray()));
        await rg.WriteColumnAsync(new DataColumn(Fields[9], rows.Select(r => Long(r, "SkuCapacity")).ToArray()));
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

    private static string? Str(Dictionary<string, string?> row, string key) =>
        row.TryGetValue(key, out var v) ? v : null;

    private static long? Long(Dictionary<string, string?> row, string key)
    {
        if (!row.TryGetValue(key, out var v) || string.IsNullOrEmpty(v)) return null;
        return long.TryParse(v, out var result) ? result : null;
    }

    private static DateTime? Dt(Dictionary<string, string?> row, string key)
    {
        if (!row.TryGetValue(key, out var v) || string.IsNullOrEmpty(v)) return null;
        return DateTimeOffset.TryParse(v, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var dto)
            ? dto.UtcDateTime
            : null;
    }
}
