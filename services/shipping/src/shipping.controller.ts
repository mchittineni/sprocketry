import { Controller, Get, NotFoundException, Param, ParseIntPipe } from '@nestjs/common';
import { ShippingService } from './shipping.service.js';

@Controller()
export class ShippingController {
  constructor(private readonly shipping: ShippingService) {}

  @Get('healthz')
  health() {
    return { status: 'ok' };
  }

  @Get('countries')
  countries() {
    return this.shipping.countries();
  }

  @Get('cities/:country')
  cities(@Param('country') country: string) {
    return this.shipping.cities(country.toUpperCase());
  }

  @Get('quote/:cityId')
  async quote(@Param('cityId', ParseIntPipe) cityId: number) {
    const quote = await this.shipping.quote(cityId);
    if (!quote) throw new NotFoundException('unknown city');
    return quote;
  }
}
