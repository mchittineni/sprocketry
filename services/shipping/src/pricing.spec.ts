import { test } from 'node:test';
import assert from 'node:assert/strict';
import { haversineKm, priceFor } from './pricing';

test('London to Manchester is about 262 km', () => {
  const km = haversineKm({ lat: 51.5074, lon: -0.1278 }, { lat: 53.4808, lon: -2.2426 });
  assert.ok(Math.abs(km - 262) < 5, `got ${km}`);
});

test('price is base fee plus per-km rate', () => {
  assert.equal(priceFor(0), 5);
  assert.equal(priceFor(100), 10);
});
