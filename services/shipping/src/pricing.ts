export interface Point {
  lat: number;
  lon: number;
}

const EARTH_RADIUS_KM = 6371;
const BASE_FEE = 5;
const PER_KM = 0.05;

export function haversineKm(a: Point, b: Point): number {
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLon = rad(b.lon - a.lon);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(h));
}

export function priceFor(distanceKm: number): number {
  return Math.round((BASE_FEE + distanceKm * PER_KM) * 100) / 100;
}
