-- ===========================================
-- dc_catalog DB seed
-- 接続先: xtdb-catalog (port 5433)
-- ===========================================

-- ===========================================
-- data_source — DWH テーブル登録簿
-- connection_uri は実環境の値に置換して実行すること
-- ===========================================
INSERT INTO data_source (_id, connection_uri, table_name, sync_type, sync_schedule) VALUES
  ('neon.fct_toggl_time_entries',
   'postgresql://neondb_owner:<password>@ep-rapid-wind-a147le6e.ap-southeast-1.aws.neon.tech/neondb?sslmode=require',
   'fct_toggl_time_entries', 'api_sync', 'daily'),

  ('neon.fct_zaim_transactions',
   'postgresql://neondb_owner:<password>@ep-rapid-wind-a147le6e.ap-southeast-1.aws.neon.tech/neondb?sslmode=require',
   'fct_zaim_transactions', 'api_sync', 'daily'),

  ('neon.fct_health_body',
   'postgresql://neondb_owner:<password>@ep-rapid-wind-a147le6e.ap-southeast-1.aws.neon.tech/neondb?sslmode=require',
   'fct_health_body', 'api_sync', 'daily'),

  ('neon.fct_health_sleep',
   'postgresql://neondb_owner:<password>@ep-rapid-wind-a147le6e.ap-southeast-1.aws.neon.tech/neondb?sslmode=require',
   'fct_health_sleep', 'api_sync', 'daily'),

  ('neon.stg_fitbit__activity',
   'postgresql://neondb_owner:<password>@ep-rapid-wind-a147le6e.ap-southeast-1.aws.neon.tech/neondb?sslmode=require',
   'stg_fitbit__activity', 'api_sync', 'daily');
