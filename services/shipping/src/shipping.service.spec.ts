import 'reflect-metadata';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Pool } from 'pg';
import { ShippingService } from './shipping.service.js';

// Answers every query with the given rows and records what was asked.
function fakePool(rows: unknown[]) {
  const calls: { sql: string; params?: unknown[] }[] = [];
  const pool = {
    query: async (sql: string, params?: unknown[]) => {
      calls.push({ sql, params });
      return { rows };
    },
  };
  return { pool: pool as unknown as Pool, calls };
}

test('quote prices a known city by distance from the warehouse', async () => {
  const { pool, calls } = fakePool([{ id: 1, name: 'London', country_code: 'GB', latitude: 51.5074, longitude: -0.1278 }]);
  const quote = await new ShippingService(pool).quote(1);

  assert.deepEqual(calls[0].params, [1]);
  assert.equal(quote?.city, 'London');
  assert.equal(quote?.country, 'GB');
  assert.ok(Math.abs((quote?.distanceKm ?? 0) - 262) < 5, `got ${quote?.distanceKm}`);
  assert.ok(Math.abs((quote?.cost ?? 0) - 18.1) < 0.3, `got ${quote?.cost}`);
});

test('quote is undefined for an unknown city', async () => {
  const { pool } = fakePool([]);
  assert.equal(await new ShippingService(pool).quote(999), undefined);
});

test('cities are looked up with a bound parameter, not interpolated', async () => {
  const { pool, calls } = fakePool([{ id: 1, name: 'London' }]);
  await new ShippingService(pool).cities("GB' OR '1'='1");

  assert.ok(!calls[0].sql.includes('GB'));
  assert.deepEqual(calls[0].params, ["GB' OR '1'='1"]);
});
