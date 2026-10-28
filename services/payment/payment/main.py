"""Payment service: charges a cart, publishes an OrderPlaced event, then clears the cart."""

import asyncio
import logging
import os
import random
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from decimal import Decimal
from typing import Annotated, Any

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format='{"level":"%(levelname)s","msg":"%(message)s"}')
log = logging.getLogger("payment")

DAPR_URL = f"http://localhost:{os.getenv('DAPR_HTTP_PORT', '3500')}"
PUBSUB = os.getenv("PUBSUB_NAME", "pubsub")
ORDERS_TOPIC = os.getenv("ORDERS_TOPIC", "orders")

# Fault injection knobs, the equivalent of robot-shop's built-in failure modes.
FAILURE_RATE = float(os.getenv("PAYMENT_FAILURE_RATE", "0"))
DELAY_MS = int(os.getenv("PAYMENT_DELAY_MS", "0"))

# Order IDs are derived from the cart and its version, so paying twice for the same cart contents
# (a double submit, or a retry after a timeout) places one order.
ORDER_NAMESPACE = uuid.UUID("5d2c7d4e-3f0a-4b8e-9a51-6f2b1c9e8d70")
CENTS = Decimal("0.01")


class Dapr:
    """Thin wrapper over the Dapr sidecar HTTP API; swapped out in tests."""

    def __init__(self, client: httpx.AsyncClient):
        self.client = client

    async def invoke(self, app_id: str, method: str, path: str, json: Any = None) -> httpx.Response:
        return await self.client.request(method, f"{DAPR_URL}/v1.0/invoke/{app_id}/method/{path}", json=json)

    async def publish(self, topic: str, data: dict) -> None:
        resp = await self.client.post(f"{DAPR_URL}/v1.0/publish/{PUBSUB}/{topic}", json=data)
        resp.raise_for_status()


@asynccontextmanager
async def lifespan(app: FastAPI):
    # One client for the process, so calls to the sidecar reuse pooled connections.
    async with httpx.AsyncClient(timeout=10) as client:
        app.state.dapr = Dapr(client)
        yield


def get_dapr(request: Request) -> Dapr:
    return request.app.state.dapr


class Checkout(BaseModel):
    user_id: str
    city_id: int


class Order(BaseModel):
    order_id: str
    cart_id: str
    user_id: str
    items: list[dict]
    subtotal: float
    shipping: float
    total: float
    placed_at: datetime


def money(value: Any) -> Decimal:
    # Via str, so a JSON float such as 18.1 becomes exactly 18.10 rather than its binary approximation.
    return Decimal(str(value)).quantize(CENTS)


app = FastAPI(title="payment", lifespan=lifespan)


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.post("/pay/{cart_id}", response_model=Order)
async def pay(cart_id: str, checkout: Checkout, dapr: Annotated[Dapr, Depends(get_dapr)]) -> Order:
    cart_resp = await dapr.invoke("cart", "GET", f"cart/{cart_id}")
    cart_resp.raise_for_status()
    cart = cart_resp.json()
    if not cart.get("items"):
        raise HTTPException(status_code=400, detail="cart is empty")

    quote_resp = await dapr.invoke("shipping", "GET", f"quote/{checkout.city_id}")
    if quote_resp.status_code == 404:
        raise HTTPException(status_code=400, detail="unknown city")
    quote_resp.raise_for_status()
    shipping = money(quote_resp.json()["cost"])

    if DELAY_MS:
        await asyncio.sleep(DELAY_MS / 1000)
    if random.random() < FAILURE_RATE:
        log.warning("payment gateway declined cart %s (injected fault)", cart_id)
        raise HTTPException(status_code=502, detail="payment gateway error")

    order_id = str(uuid.uuid5(ORDER_NAMESPACE, f"{cart_id}:{cart.get('version', 0)}"))
    subtotal = money(cart["total"])

    # Stock is taken before the order is announced, so two shoppers cannot both buy the last unit.
    # Reserving an order ID twice is a no-op in the catalog.
    reservation = [{"sku": i["sku"], "quantity": i["quantity"]} for i in cart["items"]]
    reserve_resp = await dapr.invoke("catalog", "POST", f"orders/{order_id}/reservation", json={"items": reservation})
    if reserve_resp.status_code in (404, 409):
        raise HTTPException(status_code=409, detail=f"out of stock: {reserve_resp.text}")
    reserve_resp.raise_for_status()

    order = Order(
        order_id=order_id,
        cart_id=cart_id,
        user_id=checkout.user_id,
        items=cart["items"],
        subtotal=float(subtotal),
        shipping=float(shipping),
        total=float(subtotal + shipping),
        placed_at=datetime.now(UTC),
    )
    try:
        await dapr.publish(ORDERS_TOPIC, order.model_dump(mode="json"))
    except httpx.HTTPError as err:
        # Nothing downstream knows about the order, so put its stock back and let the shopper retry.
        log.error("order %s not published: %s", order_id, err)
        try:
            (await dapr.invoke("catalog", "DELETE", f"orders/{order_id}/reservation")).raise_for_status()
        except httpx.HTTPError as release_err:
            log.error("order %s stock not released: %s", order_id, release_err)
        raise HTTPException(status_code=502, detail="order could not be placed") from err
    log.info("order %s placed for cart %s", order.order_id, cart_id)

    # The order is placed once it is published. Failing the request now would tell the shopper they
    # were not charged and invite a retry that places the order twice, so a stale cart is only logged.
    try:
        (await dapr.invoke("cart", "DELETE", f"cart/{cart_id}")).raise_for_status()
    except httpx.HTTPError as err:
        log.error("order %s placed but cart %s was not cleared: %s", order.order_id, cart_id, err)
    return order
