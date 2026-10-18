-- 0008_tax_precision: tax rates need more than 4 decimal places.
-- Quebec GST + QST is 14.975% (0.14975); numeric(7,4) stored it as 0.1498.

alter table tax_presets alter column rate type numeric(9,6);
alter table tax_rates   alter column rate type numeric(9,6);

update tax_presets set rate = 0.14975 where code = 'CA-QC-GSTQST';
update tax_rates   set rate = 0.14975 where code = 'CA-QC-GSTQST' and rate = 0.1498;
