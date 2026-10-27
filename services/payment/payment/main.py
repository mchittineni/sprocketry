"""Payment service: charges a cart, publishes an OrderPlaced event, then clears the cart."""

import asyncio
import logging
import os
import random
import uuid
from datetime import UTC, datetime
from typing import Annotated

import httpx
from fastapi import Depends, FastAPI, HTTPException
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format='{"level":"%(levelname)s","msg":"%(message)s"}')
log = logging.getLogger("payment")

DAPR_URL = f"http://localhost:{os.getenv('DAPR_HTTP_PORT', '3500')}"
PUBSUB = os.getenv("PUBSUB_NAME", "pubsub")
ORDERS_TOPIC = os.getenv("ORDERS_TOPIC", "orders")

# Fault injection knobs, the equivalent of robot-shop's built-in failure modes.
FAILURE_RATE = float(os.getenv("PAYMENT_FAILURE_RATE", "0"))
DELAY_MS = int(os.getenv("PAYMENT_DELAY_MS", "0"))


class Dapr:
    """Thin wrapper over the Dapr sidecar HTTP API; swapped out in tests."""

    def __init__(self, client: httpx.AsyncClient):
        self.client = client

    async def invoke(self, app_id: str, method: str, path: str) -> httpx.Response:
        return await self.client.request(method, f"{DAPR_URL}/v1.0/invoke/{app_id}/method/{path}")

    async def publish(self, topic: str, data: dict) -> None:
        resp = await self.client.post(f"{DAPR_URL}/v1.0/publish/{PUBSUB}/{topic}", json=data)
        resp.raise_for_status()


async def get_dapr():
    async with httpx.AsyncClient(timeout=10) as client:
        yield Dapr(client)


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


app = FastAPI(title="payment")


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
    shipping = float(quote_resp.json()["cost"])

    if DELAY_MS:
        await asyncio.sleep(DELAY_MS / 1000)
    if random.random() < FAILURE_RATE:
        log.warning("payment gateway declined cart %s (injected fault)", cart_id)
        raise HTTPException(status_code=502, detail="payment gateway error")

    subtotal = float(cart["total"])
    order = Order(
        order_id=str(uuid.uuid4()),
        cart_id=cart_id,
        user_id=checkout.user_id,
        items=cart["items"],
        subtotal=subtotal,
        shipping=shipping,
        total=round(subtotal + shipping, 2),
        placed_at=datetime.now(UTC),
    )
    await dapr.publish(ORDERS_TOPIC, order.model_dump(mode="json"))
    (await dapr.invoke("cart", "DELETE", f"cart/{cart_id}")).raise_for_status()
    log.info("order %s placed for cart %s", order.order_id, cart_id)
    return order
