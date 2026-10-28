// Cart service: keeps shopping carts in the Dapr state store (Valkey locally, Azure Redis in cloud).
using System.Net;
using Microsoft.AspNetCore.Http.HttpResults;

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.AddJsonConsole();

var daprPort = Environment.GetEnvironmentVariable("DAPR_HTTP_PORT") ?? "3500";
var stateStore = Environment.GetEnvironmentVariable("STATE_STORE") ?? "statestore";
builder.Services.AddHttpClient("dapr", c => c.BaseAddress = new Uri($"http://localhost:{daprPort}"));

var app = builder.Build();

app.MapGet("/healthz", () => Results.Ok());

app.MapGet("/cart/{id}", async (string id, IHttpClientFactory http) =>
    Results.Ok((await LoadCart(http.CreateClient("dapr"), stateStore, id)).Cart));

app.MapPost("/cart/{id}/items", async (string id, AddItem req, IHttpClientFactory http) =>
{
    // The JSON binder leaves a missing sku null despite the non-nullable type.
    if (string.IsNullOrWhiteSpace(req.Sku)) return Results.BadRequest("sku is required");
    if (req.Quantity <= 0) return Results.BadRequest("quantity must be positive");

    var dapr = http.CreateClient("dapr");
    var product = await GetProduct(dapr, req.Sku);
    if (product is null) return Results.NotFound("unknown sku");

    return await UpdateCart(dapr, stateStore, id, cart =>
    {
        var existing = cart.Items.FirstOrDefault(i => i.Sku == product.Sku);
        var quantity = (existing?.Quantity ?? 0) + req.Quantity;
        return quantity > product.Stock ? StockConflict(product) : SetLine(cart, product, quantity);
    });
});

// Sets a line to an exact quantity; 0 removes it.
app.MapPut("/cart/{id}/items/{sku}", async (string id, string sku, SetQuantity req, IHttpClientFactory http) =>
{
    if (req.Quantity < 0) return Results.BadRequest("quantity must not be negative");

    var dapr = http.CreateClient("dapr");
    if (req.Quantity == 0)
        return await UpdateCart(dapr, stateStore, id, cart => TypedResults.Ok(RemoveLine(cart, sku)));

    var product = await GetProduct(dapr, sku);
    if (product is null) return Results.NotFound("unknown sku");
    if (req.Quantity > product.Stock) return StockConflict(product);
    return await UpdateCart(dapr, stateStore, id, cart => SetLine(cart, product, req.Quantity));
});

app.MapDelete("/cart/{id}/items/{sku}", async (string id, string sku, IHttpClientFactory http) =>
    await UpdateCart(http.CreateClient("dapr"), stateStore, id, cart => TypedResults.Ok(RemoveLine(cart, sku))));

app.MapDelete("/cart/{id}", async (string id, IHttpClientFactory http) =>
{
    var resp = await http.CreateClient("dapr").DeleteAsync($"/v1.0/state/{stateStore}/{Uri.EscapeDataString(id)}");
    resp.EnsureSuccessStatusCode();
    return Results.NoContent();
});

app.Run($"http://0.0.0.0:{Environment.GetEnvironmentVariable("PORT") ?? "8080"}");

static async Task<Product?> GetProduct(HttpClient dapr, string sku)
{
    var resp = await dapr.GetAsync($"/v1.0/invoke/catalog/method/products/{Uri.EscapeDataString(sku)}");
    if (resp.StatusCode == HttpStatusCode.NotFound) return null;
    resp.EnsureSuccessStatusCode();
    return await resp.Content.ReadFromJsonAsync<Product>();
}

static IResult StockConflict(Product product) =>
    Results.Conflict(product.Stock <= 0 ? "out of stock" : $"only {product.Stock} in stock");

static IResult SetLine(Cart cart, Product product, int quantity)
{
    var items = cart.Items.Where(i => i.Sku != product.Sku).ToList();
    var index = cart.Items.FindIndex(i => i.Sku == product.Sku);
    // Keep the line where it was, so changing a quantity doesn't reorder the cart.
    items.Insert(index < 0 ? items.Count : index, new CartItem(product.Sku, product.Name, product.Price, quantity));
    return TypedResults.Ok(cart with { Items = items });
}

static Cart RemoveLine(Cart cart, string sku) => cart with { Items = cart.Items.Where(i => i.Sku != sku).ToList() };

static async Task<(Cart Cart, string? ETag)> LoadCart(HttpClient dapr, string store, string id)
{
    var resp = await dapr.GetAsync($"/v1.0/state/{store}/{Uri.EscapeDataString(id)}");
    resp.EnsureSuccessStatusCode();
    // Dapr returns 204 No Content when the key does not exist.
    if (resp.StatusCode == HttpStatusCode.NoContent) return (new Cart(id, []), null);
    // Dapr's ETag is not a quoted HTTP entity tag, so read it unvalidated.
    var etag = resp.Headers.NonValidated.TryGetValues("ETag", out var values) ? values.ToString() : null;
    return (await resp.Content.ReadFromJsonAsync<Cart>() ?? new Cart(id, []), etag);
}

// Read-modify-write with optimistic concurrency: the save is refused if another request changed the cart
// after it was read, and the change is then reapplied to the fresh cart. change returns TypedResults.Ok(cart)
// to save that cart, or any other result to stop without saving.
static async Task<IResult> UpdateCart(HttpClient dapr, string store, string id, Func<Cart, IResult> change)
{
    const int maxAttempts = 5;
    for (var attempt = 1; ; attempt++)
    {
        var (cart, etag) = await LoadCart(dapr, store, id);
        var result = change(cart);
        if (result is not Ok<Cart> { Value: { } changed }) return result;

        var saved = changed with { Version = cart.Version + 1 };
        var resp = await dapr.PostAsJsonAsync($"/v1.0/state/{store}", new[]
        {
            new { key = id, value = saved, etag, options = new { concurrency = "first-write" } },
        });
        // A stale ETag is a 409. Creating a cart that another request has just created (no ETag, key now
        // exists) is refused too, but Dapr reports that as a 500 ERR_STATE_SAVE, so retry both.
        var conflict = resp.StatusCode == HttpStatusCode.Conflict
            || (etag is null && resp.StatusCode == HttpStatusCode.InternalServerError);
        if (conflict && attempt == maxAttempts) return Results.Conflict("cart is busy, try again");
        if (conflict)
        {
            // Jittered backoff, so writers racing for the same cart don't collide again in lockstep.
            await Task.Delay(Random.Shared.Next(10, 30) * attempt);
            continue;
        }
        resp.EnsureSuccessStatusCode();
        return Results.Ok(saved);
    }
}

sealed record AddItem(string Sku, int Quantity);
sealed record SetQuantity(int Quantity);
sealed record Product(string Sku, string Name, decimal Price, int Stock);
sealed record CartItem(string Sku, string Name, decimal Price, int Quantity);

// Version increases on every save. Payment derives the order ID from it, so paying twice for the same
// cart contents places one order.
sealed record Cart(string Id, List<CartItem> Items, int Version = 0)
{
    public decimal Total => Items.Sum(i => i.Price * i.Quantity);
}
