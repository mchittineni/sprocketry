using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Cart.Tests;

// Stands in for the Dapr sidecar: an in-memory state store with ETags, and the catalog behind service invocation.
public class FakeDapr : HttpMessageHandler
{
    private readonly Dictionary<string, (string Json, int ETag)> state = [];

    public Dictionary<string, JsonObject> Products { get; } = new()
    {
        ["RB-001"] = new() { ["sku"] = "RB-001", ["name"] = "Cargo Bot", ["price"] = 1299.00m, ["stock"] = 12 },
        ["RB-002"] = new() { ["sku"] = "RB-002", ["name"] = "Sweep Bot", ["price"] = 349.00m, ["stock"] = 40 },
        ["RB-006"] = new() { ["sku"] = "RB-006", ["name"] = "Sentinel", ["price"] = 1899.00m, ["stock"] = 0 },
    };

    // Runs once, just before the next save is applied, to simulate a concurrent writer.
    public Action? BeforeNextSave { get; set; }

    public int Saves { get; private set; }

    // Refuses every save as if another writer always got there first.
    public bool AlwaysConflict { get; set; }

    public void Put(string key, string json) => state[key] = (json, state.TryGetValue(key, out var s) ? s.ETag + 1 : 1);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
    {
        var path = req.RequestUri!.AbsolutePath;
        const string statePrefix = "/v1.0/state/statestore";
        const string catalogPrefix = "/v1.0/invoke/catalog/method/products/";

        if (path.StartsWith(catalogPrefix) && req.Method == HttpMethod.Get)
        {
            return Products.TryGetValue(Uri.UnescapeDataString(path[catalogPrefix.Length..]), out var p)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(p) }
                : new HttpResponseMessage(HttpStatusCode.NotFound);
        }

        if (path == statePrefix && req.Method == HttpMethod.Post)
        {
            if (AlwaysConflict) return new HttpResponseMessage(HttpStatusCode.Conflict);
            var batch = JsonNode.Parse(await req.Content!.ReadAsStringAsync(ct))!.AsArray();
            if (BeforeNextSave is { } hook)
            {
                BeforeNextSave = null;
                hook();
            }
            foreach (var item in batch)
            {
                var key = item!["key"]!.GetValue<string>();
                var etag = item["etag"]?.GetValue<string>();
                var exists = state.TryGetValue(key, out var current);
                // First-write refuses a stale ETag with 409, and no ETag for a key that now exists with 500,
                // which is what Dapr's Redis state store does.
                if (etag is null && exists) return new HttpResponseMessage(HttpStatusCode.InternalServerError);
                if (etag is not null && (!exists || etag != current.ETag.ToString()))
                    return new HttpResponseMessage(HttpStatusCode.Conflict);
                Put(key, item["value"]!.ToJsonString());
                Saves++;
            }
            return new HttpResponseMessage(HttpStatusCode.NoContent);
        }

        if (path.StartsWith(statePrefix + "/"))
        {
            var key = Uri.UnescapeDataString(path[(statePrefix.Length + 1)..]);
            if (req.Method == HttpMethod.Delete)
            {
                state.Remove(key);
                return new HttpResponseMessage(HttpStatusCode.NoContent);
            }
            if (!state.TryGetValue(key, out var entry)) return new HttpResponseMessage(HttpStatusCode.NoContent);
            var resp = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(entry.Json) };
            resp.Headers.TryAddWithoutValidation("ETag", entry.ETag.ToString());
            return resp;
        }

        throw new InvalidOperationException($"unexpected Dapr call {req.Method} {path}");
    }
}

public record CartDto(string Id, List<LineDto> Items, int Version, decimal Total);
public record LineDto(string Sku, string Name, decimal Price, int Quantity);

public class CartApiTests : IDisposable
{
    private readonly FakeDapr dapr = new();
    private readonly WebApplicationFactory<Program> factory;
    private readonly HttpClient client;

    public CartApiTests()
    {
        factory = new WebApplicationFactory<Program>().WithWebHostBuilder(b => b.ConfigureTestServices(services =>
            services.AddHttpClient("dapr").ConfigurePrimaryHttpMessageHandler(() => dapr)));
        client = factory.CreateClient();
    }

    public void Dispose()
    {
        client.Dispose();
        factory.Dispose();
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private async Task<HttpResponseMessage> Add(string sku, int quantity) =>
        await client.PostAsJsonAsync("/cart/c1/items", new { sku, quantity }, Ct);

    private async Task<HttpResponseMessage> Set(string sku, int quantity) =>
        await client.PutAsJsonAsync($"/cart/c1/items/{sku}", new { quantity }, Ct);

    private async Task<CartDto> Get() => (await client.GetFromJsonAsync<CartDto>("/cart/c1", Ct))!;

    [Fact]
    public async Task UnknownCartIsEmpty()
    {
        var cart = await Get();
        Assert.Empty(cart.Items);
        Assert.Equal(0, cart.Version);
    }

    [Fact]
    public async Task AddingMergesLinesAndTotals()
    {
        Assert.Equal(HttpStatusCode.OK, (await Add("RB-002", 1)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await Add("RB-002", 2)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await Add("RB-001", 1)).StatusCode);

        var cart = await Get();
        Assert.Equal(["RB-002", "RB-001"], cart.Items.Select(i => i.Sku));
        Assert.Equal(3, cart.Items[0].Quantity);
        Assert.Equal(3 * 349m + 1299m, cart.Total);
        Assert.Equal(3, cart.Version);
    }

    [Theory]
    [InlineData("""{"quantity":1}""", "sku is required")]
    [InlineData("""{"sku":"RB-002","quantity":0}""", "quantity must be positive")]
    public async Task InvalidAddIsRejected(string body, string message)
    {
        var resp = await client.PostAsync("/cart/c1/items", new StringContent(body, null, "application/json"), Ct);
        Assert.Equal(HttpStatusCode.BadRequest, resp.StatusCode);
        Assert.Contains(message, await resp.Content.ReadAsStringAsync(Ct));
    }

    [Fact]
    public async Task UnknownSkuIsNotFound()
    {
        Assert.Equal(HttpStatusCode.NotFound, (await Add("NOPE", 1)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await Set("NOPE", 1)).StatusCode);
    }

    [Fact]
    public async Task CannotAddMoreThanInStock()
    {
        var soldOut = await Add("RB-006", 1);
        Assert.Equal(HttpStatusCode.Conflict, soldOut.StatusCode);
        Assert.Contains("out of stock", await soldOut.Content.ReadAsStringAsync(Ct));

        await Add("RB-001", 10);
        var tooMany = await Add("RB-001", 3);
        Assert.Equal(HttpStatusCode.Conflict, tooMany.StatusCode);
        Assert.Contains("only 12 in stock", await tooMany.Content.ReadAsStringAsync(Ct));
        Assert.Equal(10, (await Get()).Items.Single().Quantity);
    }

    [Fact]
    public async Task SetQuantityKeepsLineOrder()
    {
        await Add("RB-002", 3);
        await Add("RB-001", 1);

        Assert.Equal(HttpStatusCode.OK, (await Set("RB-002", 1)).StatusCode);

        var cart = await Get();
        Assert.Equal(["RB-002", "RB-001"], cart.Items.Select(i => i.Sku));
        Assert.Equal(1, cart.Items[0].Quantity);
    }

    // Lowering a quantity must never lose the line, even when stock has since run out.
    [Fact]
    public async Task LoweringQuantityWithinStockSucceedsAndAboveStockLeavesLine()
    {
        await Add("RB-001", 5);
        dapr.Products["RB-001"]["stock"] = 2;

        Assert.Equal(HttpStatusCode.Conflict, (await Set("RB-001", 4)).StatusCode);
        Assert.Equal(5, (await Get()).Items.Single().Quantity);

        Assert.Equal(HttpStatusCode.OK, (await Set("RB-001", 2)).StatusCode);
        Assert.Equal(2, (await Get()).Items.Single().Quantity);
    }

    [Fact]
    public async Task SettingZeroOrDeletingRemovesLine()
    {
        await Add("RB-002", 2);
        await Add("RB-001", 1);

        Assert.Equal(HttpStatusCode.OK, (await Set("RB-002", 0)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.DeleteAsync("/cart/c1/items/RB-001", Ct)).StatusCode);
        Assert.Empty((await Get()).Items);

        Assert.Equal(HttpStatusCode.BadRequest, (await Set("RB-002", -1)).StatusCode);
    }

    [Fact]
    public async Task DeletingCartEmptiesIt()
    {
        await Add("RB-002", 1);
        Assert.Equal(HttpStatusCode.NoContent, (await client.DeleteAsync("/cart/c1", Ct)).StatusCode);
        Assert.Empty((await Get()).Items);
    }

    // Payment's order ID comes from the cart version, so a cart refilled after checkout must not repeat one.
    [Fact]
    public async Task VersionKeepsRisingAfterCheckoutEmptiesCart()
    {
        await Add("RB-002", 1);
        var paid = (await Get()).Version;
        await client.DeleteAsync("/cart/c1", Ct);
        await Add("RB-002", 1);

        Assert.True((await Get()).Version > paid);
    }

    // A write that lands between this request's read and save must not be overwritten.
    [Fact]
    public async Task ConcurrentChangeIsRetriedNotLost()
    {
        await Add("RB-002", 1);
        dapr.BeforeNextSave = () => dapr.Put("c1", JsonSerializer.Serialize(new
        {
            id = "c1",
            items = new[] { new { sku = "RB-002", name = "Sweep Bot", price = 349m, quantity = 1 }, new { sku = "RB-001", name = "Cargo Bot", price = 1299m, quantity = 1 } },
            version = 2,
        }));

        Assert.Equal(HttpStatusCode.OK, (await Add("RB-002", 1)).StatusCode);

        var cart = await Get();
        Assert.Equal(2, cart.Items.Single(i => i.Sku == "RB-002").Quantity);
        Assert.Equal(1, cart.Items.Single(i => i.Sku == "RB-001").Quantity);
        Assert.Equal(3, cart.Version);
    }

    // Two requests creating the same cart: the second save has no ETag for a key that now exists.
    [Fact]
    public async Task ConcurrentCreateIsRetriedNotLost()
    {
        dapr.BeforeNextSave = () => dapr.Put("c1", JsonSerializer.Serialize(new
        {
            id = "c1",
            items = new[] { new { sku = "RB-001", name = "Cargo Bot", price = 1299m, quantity = 1 } },
            version = 1,
        }));

        Assert.Equal(HttpStatusCode.OK, (await Add("RB-002", 1)).StatusCode);

        var cart = await Get();
        Assert.Equal(["RB-001", "RB-002"], cart.Items.Select(i => i.Sku));
        Assert.Equal(2, cart.Version);
    }

    // A cart that never stops changing is refused with a retryable 409, not a 500.
    [Fact]
    public async Task PersistentContentionIsAConflict()
    {
        await Add("RB-002", 1);
        dapr.AlwaysConflict = true;

        var resp = await Add("RB-002", 1);

        Assert.Equal(HttpStatusCode.Conflict, resp.StatusCode);
        Assert.Contains("cart is busy", await resp.Content.ReadAsStringAsync(Ct));
    }
}
