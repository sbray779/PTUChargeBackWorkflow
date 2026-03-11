using System.IO.Compression;
using System.Net;
using System.Text;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;

namespace ZipCsvFunction;

public class ZipCsv
{
    [Function("ZipCsv")]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = null)] HttpRequestData req)
    {
        using var reader = new StreamReader(req.Body, Encoding.UTF8);
        var csvContent = await reader.ReadToEndAsync();
        var csvBytes = Encoding.UTF8.GetBytes(csvContent);

        var filename = req.Query["filename"];
        if (string.IsNullOrWhiteSpace(filename))
            filename = "chargeBack-daily.csv";
        else
            filename = Path.GetFileNameWithoutExtension(filename) + ".csv";

        using var ms = new MemoryStream();
        using (var archive = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            var entry = archive.CreateEntry(filename, CompressionLevel.Optimal);
            using var entryStream = entry.Open();
            await entryStream.WriteAsync(csvBytes);
        }

        ms.Position = 0;
        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/zip");
        await ms.CopyToAsync(response.Body);
        return response;
    }
}
