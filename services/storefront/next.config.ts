import type { NextConfig } from 'next';

const config: NextConfig = {
  output: 'standalone',
  // The app uses no raster images. Keeping the optimiser off means its native sharp dependency is never
  // loaded, which lets the image be cross-built on one CPU and run on another (see Dockerfile).
  images: { unoptimized: true },
};

export default config;
