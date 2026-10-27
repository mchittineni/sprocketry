import { Inject, Injectable, OnModuleDestroy, OnModuleInit, Provider } from '@nestjs/common';
import { readFile } from 'node:fs/promises';
import { Pool } from 'pg';
import { haversineKm, priceFor } from './pricing.js';

const PG_POOL = Symbol('PG_POOL');

export const pgPoolProvider: Provider = {
  provide: PG_POOL,
  useFactory: () =>
    new Pool({ connectionString: process.env.DATABASE_URL ?? 'postgres://sprocketry:sprocketry@localhost:5432/shipping' }),
};

// Warehouse location; defaults to Manchester, UK.
const WAREHOUSE = {
  lat: Number(process.env.WAREHOUSE_LAT ?? 53.4808),
  lon: Number(process.env.WAREHOUSE_LON ?? -2.2426),
};

export interface Quote {
  cityId: number;
  city: string;
  country: string;
  distanceKm: number;
  cost: number;
}

@Injectable()
export class ShippingService implements OnModuleInit, OnModuleDestroy {
  constructor(@Inject(PG_POOL) private readonly pool: Pool) {}

  // The schema is idempotent, so it is safe to apply on every start.
  async onModuleInit() {
    const schema = await readFile(new URL('../db/schema.sql', import.meta.url), 'utf8');
    await this.pool.query(schema);
  }

  async countries(): Promise<{ code: string; name: string }[]> {
    const { rows } = await this.pool.query('SELECT code, name FROM countries ORDER BY name');
    return rows;
  }

  async cities(country: string): Promise<{ id: number; name: string }[]> {
    const { rows } = await this.pool.query(
      'SELECT id, name FROM cities WHERE country_code = $1 ORDER BY name',
      [country],
    );
    return rows;
  }

  async quote(cityId: number): Promise<Quote | undefined> {
    const { rows } = await this.pool.query(
      'SELECT id, name, country_code, latitude, longitude FROM cities WHERE id = $1',
      [cityId],
    );
    const city = rows[0];
    if (!city) return undefined;

    const distanceKm = haversineKm(WAREHOUSE, { lat: city.latitude, lon: city.longitude });
    return {
      cityId: city.id,
      city: city.name,
      country: city.country_code,
      distanceKm: Math.round(distanceKm),
      cost: priceFor(distanceKm),
    };
  }

  async onModuleDestroy() {
    await this.pool.end();
  }
}
