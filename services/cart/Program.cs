// Cart service: keeps shopping carts in the Dapr state store (Valkey locally, Azure Redis in cloud).
using System.Net;

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.AddJsonConsole();

var daprPort = Environment.GetEnvironmentVariable("DAPR_HTTP_PORT") ?? "3500";
var stateStore = Environment.GetEnvironmentVariable("STATE_STORE") ?? "statestore";
builder.Services.AddHttpClient("dapr", c => c.BaseAddress = new Uri($"http://localhost:{daprPort}"));

var app = builder.Build();

app.MapGet("/healthz", () => Results.Ok());

app.MapGet("/cart/{id}", async (string id, IHttpClientFactory http) =>
    Results.Ok(await LoadCart(http.CreateClient("dapr"), stateStore, id)));

app.MapPost("/cart/{id}/items", async (string id, AddItem req, IHttpClientFactory http) =>
{
    if (req.Quantity <= 0) return Results.BadRequest("quantity must be positive");

    var dapr = http.CreateClient("dapr");
    var productResp = await dapr.GetAsync($"/v1.0/invoke/catalog/method/products/{Uri.EscapeDataString(req.Sku)}");
    if (productResp.StatusCode == HttpStatusCode.NotFound) return Results.NotFound("unknown sku");
    productResp.EnsureSuccessStatusCode();
    var product = await productResp.Content.ReadFromJsonAsync<Product>();
    if (product is null || product.Stock <= 0) return Results.Conflict("out of stock");

    var cart = await LoadCart(dapr, stateStore, id);
    var existing = cart.Items.FirstOrDefault(i => i.Sku == product.Sku);
    if (existing is null)
        cart.Items.Add(new CartItem(product.Sku, product.Name, product.Price, req.Quantity));
    else
        cart.Items[cart.Items.IndexOf(existing)] = existing with { Quantity = existing.Quantity + req.Quantity };

    await SaveCart(dapr, stateStore, cart);
    return Results.Ok(cart);
});

app.MapDelete("/cart/{id}/items/{sku}", async (string id, string sku, IHttpClientFactory http) =>
{
    var dapr = http.CreateClient("dapr");
    var cart = await LoadCart(dapr, stateStore, id);
    cart.Items.RemoveAll(i => i.Sku == sku);
    await SaveCart(dapr, stateStore, cart);
    return Results.Ok(cart);
});

app.MapDelete("/cart/{id}", async (string id, IHttpClientFactory http) =>
{
    var resp = await http.CreateClient("dapr").DeleteAsync($"/v1.0/state/{stateStore}/{Uri.EscapeDataString(id)}");
    resp.EnsureSuccessStatusCode();
    return Results.NoContent();
});

app.Run($"http://0.0.0.0:{Environment.GetEnvironmentVariable("PORT") ?? "8080"}");

static async Task<Cart> LoadCart(HttpClient dapr, string store, string id)
{
    var resp = await dapr.GetAsync($"/v1.0/state/{store}/{Uri.EscapeDataString(id)}");
    resp.EnsureSuccessStatusCode();
    // Dapr returns 204 No Content when the key does not exist.
    if (resp.StatusCode == HttpStatusCode.NoContent) return new Cart(id, []);
    return await resp.Content.ReadFromJsonAsync<Cart>() ?? new Cart(id, []);
}

static async Task SaveCart(HttpClient dapr, string store, Cart cart)
{
    var resp = await dapr.PostAsJsonAsync($"/v1.0/state/{store}", new[] { new { key = cart.Id, value = cart } });
    resp.EnsureSuccessStatusCode();
}

record AddItem(string Sku, int Quantity);
record Product(string Sku, string Name, decimal Price, int Stock);
record CartItem(string Sku, string Name, decimal Price, int Quantity);
record Cart(string Id, List<CartItem> Items)
{
    public decimal Total => Items.Sum(i => i.Price * i.Quantity);
}
