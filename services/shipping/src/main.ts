import 'reflect-metadata';
import { Module } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { ShippingController } from './shipping.controller.js';
import { ShippingService, pgPoolProvider } from './shipping.service.js';

@Module({
  controllers: [ShippingController],
  providers: [pgPoolProvider, ShippingService],
})
class AppModule {}

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  app.enableShutdownHooks();
  await app.listen(Number(process.env.PORT ?? 8080), '0.0.0.0');
}

bootstrap();
