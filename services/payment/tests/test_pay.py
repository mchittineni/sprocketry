import httpx
from fastapi.testclient import TestClient

from payment.main import app, get_dapr

CART = {"id": "c1", "items": [{"sku": "RB-002", "name": "Sweep Bot", "price": 349.0, "quantity": 2}], "total": 698.0}


class FakeDapr:
    def __init__(self, cart):
        self.cart = cart
        self.published = []
        self.deleted = False

    async def invoke(self, app_id, method, path):
        request = httpx.Request(method, f"http://dapr/{app_id}/{path}")
        if app_id == "cart" and method == "GET":
            return httpx.Response(200, json=self.cart, request=request)
        if app_id == "cart" and method == "DELETE":
            self.deleted = True
            return httpx.Response(204, request=request)
        if app_id == "shipping":
            return httpx.Response(200, json={"cost": 18.1}, request=request)
        raise AssertionError(f"unexpected call {app_id} {method} {path}")

    async def publish(self, topic, data):
        self.published.append((topic, data))


def client_with(fake):
    app.dependency_overrides[get_dapr] = lambda: fake
    return TestClient(app)


def test_pay_publishes_order_and_clears_cart():
    fake = FakeDapr(CART)
    resp = client_with(fake).post("/pay/c1", json={"user_id": "u1", "city_id": 1})

    assert resp.status_code == 200
    assert resp.json()["total"] == 716.1
    assert fake.published[0][0] == "orders"
    assert fake.deleted


def test_empty_cart_is_rejected():
    fake = FakeDapr({"id": "c1", "items": [], "total": 0})
    resp = client_with(fake).post("/pay/c1", json={"user_id": "u1", "city_id": 1})

    assert resp.status_code == 400
    assert fake.published == []
