import httpx
import pytest
from fastapi.testclient import TestClient

import payment.main
from payment.main import app, get_dapr

CART = {
    "id": "c1",
    "items": [{"sku": "RB-002", "name": "Sweep Bot", "price": 349.0, "quantity": 2}],
    "total": 698.0,
    "version": 3,
}
CHECKOUT = {"user_id": "u1", "city_id": 1}


class FakeDapr:
    def __init__(self, cart, quote_status=200, delete_status=204, reserve_status=201, publish_fails=False, cost=18.1):
        self.cart = cart
        self.quote_status = quote_status
        self.delete_status = delete_status
        self.reserve_status = reserve_status
        self.publish_fails = publish_fails
        self.cost = cost
        self.published = []
        self.reserved = []
        self.released = []
        self.deleted = False

    async def invoke(self, app_id, method, path, json=None):
        request = httpx.Request(method, f"http://dapr/{app_id}/{path}")
        if app_id == "cart" and method == "GET":
            return httpx.Response(200, json=self.cart, request=request)
        if app_id == "cart" and method == "DELETE":
            self.deleted = True
            return httpx.Response(self.delete_status, request=request)
        if app_id == "shipping":
            return httpx.Response(self.quote_status, json={"cost": self.cost}, request=request)
        if app_id == "catalog" and method == "POST":
            self.reserved.append((path, json))
            return httpx.Response(self.reserve_status, text="out of stock: RB-002", request=request)
        if app_id == "catalog" and method == "DELETE":
            self.released.append(path)
            return httpx.Response(204, request=request)
        raise AssertionError(f"unexpected call {app_id} {method} {path}")

    async def publish(self, topic, data):
        if self.publish_fails:
            raise httpx.ConnectError("sidecar unavailable")
        self.published.append((topic, data))


@pytest.fixture
def client_with():
    def make(fake):
        app.dependency_overrides[get_dapr] = lambda: fake
        return TestClient(app)

    yield make
    app.dependency_overrides.clear()


def test_pay_publishes_order_and_clears_cart(client_with):
    fake = FakeDapr(CART)
    resp = client_with(fake).post("/pay/c1", json=CHECKOUT)

    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 716.1
    assert body["subtotal"] == 698.0
    assert body["shipping"] == 18.1
    topic, event = fake.published[0]
    assert topic == "orders"
    assert event["order_id"] == body["order_id"]
    assert event["user_id"] == "u1"
    assert fake.reserved == [
        (f"orders/{body['order_id']}/reservation", {"items": [{"sku": "RB-002", "quantity": 2}]}),
    ]
    assert fake.deleted


def test_empty_cart_is_rejected(client_with):
    fake = FakeDapr({"id": "c1", "items": [], "total": 0})
    resp = client_with(fake).post("/pay/c1", json=CHECKOUT)

    assert resp.status_code == 400
    assert fake.published == []


def test_unknown_city_is_rejected(client_with):
    fake = FakeDapr(CART, quote_status=404)
    resp = client_with(fake).post("/pay/c1", json=CHECKOUT)

    assert resp.status_code == 400
    assert resp.json()["detail"] == "unknown city"
    assert fake.published == []
    assert not fake.deleted


def test_injected_decline_places_no_order(client_with, monkeypatch):
    monkeypatch.setattr(payment.main, "FAILURE_RATE", 1.0)
    fake = FakeDapr(CART)
    resp = client_with(fake).post("/pay/c1", json=CHECKOUT)

    assert resp.status_code == 502
    assert fake.published == []
    assert fake.reserved == []
    assert not fake.deleted


# A failure here once returned 500 after the order was published, so the shopper was told they had not
# been charged and a retry placed the order twice.
def test_order_stands_when_cart_cannot_be_cleared(client_with):
    fake = FakeDapr(CART, delete_status=503)
    resp = client_with(fake).post("/pay/c1", json=CHECKOUT)

    assert resp.status_code == 200
    assert len(fake.published) == 1


def test_invalid_checkout_body_is_rejected(client_with):
    fake = FakeDapr(CART)
    resp = client_with(fake).post("/pay/c1", json={"user_id": "u1"})

    assert resp.status_code == 422
    assert fake.published == []


def test_same_cart_version_gets_same_order_id(client_with):
    first = client_with(FakeDapr(CART)).post("/pay/c1", json=CHECKOUT).json()["order_id"]
    again = client_with(FakeDapr(CART)).post("/pay/c1", json=CHECKOUT).json()["order_id"]
    changed = client_with(FakeDapr({**CART, "version": 4})).post("/pay/c1", json=CHECKOUT).json()["order_id"]

    assert first == again
    assert first != changed


@pytest.mark.parametrize("status", [404, 409])
def test_out_of_stock_places_no_order(client_with, status):
    fake = FakeDapr(CART, reserve_status=status)
    resp = client_with(fake).post("/pay/c1", json=CHECKOUT)

    assert resp.status_code == 409
    assert "out of stock" in resp.json()["detail"]
    assert fake.published == []
    assert not fake.deleted


def test_failed_publish_releases_stock_and_keeps_cart(client_with):
    fake = FakeDapr(CART, publish_fails=True)
    resp = client_with(fake).post("/pay/c1", json=CHECKOUT)

    assert resp.status_code == 502
    assert fake.released == [fake.reserved[0][0]]
    assert not fake.deleted


def test_totals_are_exact_to_the_penny(client_with):
    # 0.1 + 0.2 is 0.30000000000000004 in binary floating point.
    fake = FakeDapr({**CART, "total": 0.1}, cost=0.2)
    body = client_with(fake).post("/pay/c1", json=CHECKOUT).json()

    assert body["total"] == 0.3
