-- Reference data. Safe to run once after the migrations.
-- Tax presets are STARTING POINTS. Standard rates only. Passenger transport can
-- qualify for reduced rates in some countries, so confirm each with an accountant.

insert into plans (id, name, seat_limit, features, sort_order) values
  ('starter', 'Starter', 3,    '{"farm_out": true}'::jsonb, 1),
  ('growth',  'Growth',  15,   '{"farm_out": true}'::jsonb, 2),
  ('scale',   'Scale',   null, '{"farm_out": true}'::jsonb, 3);

insert into currencies (code, symbol, minor_unit) values
  ('USD', '$', 2), ('CAD', '$', 2), ('GBP', '£', 2), ('EUR', '€', 2);

insert into locales (code, name, status) values
  ('en', 'English',  'live'),
  ('fr', 'Français', 'live'),
  ('es', 'Español',  'review'),
  ('de', 'Deutsch',  'review'),
  ('it', 'Italiano', 'review');

insert into tax_presets (code, country, region, label, rate, kind) values
  ('CA-ON-HST',  'CA', 'ON', 'Ontario HST',          0.1300,  'HST'),
  ('CA-AB-GST',  'CA', 'AB', 'Alberta GST',          0.0500,  'GST'),
  ('CA-BC-GST',  'CA', 'BC', 'British Columbia GST', 0.0500,  'GST'),
  ('CA-QC-GSTQST','CA','QC', 'Quebec GST + QST',     0.14975, 'GST'),
  ('US-NY-NYC',  'US', 'NY', 'New York City sales tax', 0.08875, 'SALES_TAX'),
  ('US-CA-STATE','US', 'CA', 'California base sales tax', 0.0725, 'SALES_TAX'),
  ('US-TX-STATE','US', 'TX', 'Texas state sales tax', 0.0625, 'SALES_TAX'),
  ('US-NONE',    'US', null, 'No sales tax',         0.0000,  'NONE'),
  ('GB-VAT-20',  'GB', null, 'UK VAT standard',      0.2000,  'VAT'),
  ('DE-VAT-19',  'DE', null, 'Germany VAT standard', 0.1900,  'VAT'),
  ('FR-VAT-20',  'FR', null, 'France VAT standard',  0.2000,  'VAT'),
  ('ES-VAT-21',  'ES', null, 'Spain VAT standard',   0.2100,  'VAT'),
  ('IT-VAT-22',  'IT', null, 'Italy VAT standard',   0.2200,  'VAT');
