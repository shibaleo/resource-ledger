-- ===========================================
-- data_composition DB seed
-- 接続先: xtdb-dcmp (port 5432)
-- ===========================================

-- ===========================================
-- unit_master
-- ===========================================
INSERT INTO unit_master (_id, name) VALUES
  ('u-pcs',  'pcs'),
  ('u-g',    'g'),
  ('u-kg',   'kg'),
  ('u-kcal', 'kcal'),
  ('u-ml',   'ml'),
  ('u-min',  'min'),
  ('u-jpy',  'JPY');

-- ===========================================
-- resource: grocery（物品。在庫として蓄積）
-- ===========================================
INSERT INTO resource (_id, parent_id, is_leaf, cd, name, unit_id, balance_type) VALUES
  ('r-grocery',    null,         false, 'grocery',    'grocery',                       'u-pcs',  'stock'),
  ('r-beverage',   'r-grocery',  false, 'beverage',   'beverage',                      'u-pcs',  'stock'),
  ('r-monster-rr', 'r-beverage', true,  'monster-rr', 'Monster Energy Ruby Red',       'u-pcs',  'stock'),
  ('r-monster-pp', 'r-beverage', true,  'monster-pp', 'Monster Energy Pipeline Punch', 'u-pcs',  'stock');

-- ===========================================
-- resource: nutrition（栄養素。消費フロー）
-- ===========================================
INSERT INTO resource (_id, parent_id, is_leaf, cd, name, unit_id, balance_type) VALUES
  ('r-nutrition', null,           false, 'nutrition', 'nutrition', 'u-kcal', 'flow'),
  ('r-energy',    'r-nutrition',  true,  'energy',    'energy',    'u-kcal', 'flow'),
  ('r-protein',   'r-nutrition',  true,  'protein',   'protein',   'u-g',    'flow'),
  ('r-fat',       'r-nutrition',  true,  'fat',       'fat',       'u-g',    'flow'),
  ('r-carb',      'r-nutrition',  true,  'carb',      'carb',      'u-g',    'flow'),
  ('r-salt-eq',   'r-nutrition',  true,  'salt_eq',   'salt_eq',   'u-g',    'flow');

-- ===========================================
-- resource: time（時間。消費フロー）
-- ===========================================
INSERT INTO resource (_id, parent_id, is_leaf, cd, name, unit_id, balance_type) VALUES
  ('r-time',      null,       false, 'time',      'time',      'u-min', 'flow'),
  ('r-time-work', 'r-time',   false, 'time-work', 'time/work', 'u-min', 'flow'),
  ('r-time-life', 'r-time',   false, 'time-life', 'time/life', 'u-min', 'flow');

-- ===========================================
-- resource: money（金銭。フロー）
-- ===========================================
INSERT INTO resource (_id, parent_id, is_leaf, cd, name, unit_id, balance_type) VALUES
  ('r-money',         null,       false, 'money',         'money',          'u-jpy', 'flow'),
  ('r-money-income',  'r-money',  true,  'money-income',  'money/income',   'u-jpy', 'flow'),
  ('r-money-expense', 'r-money',  true,  'money-expense', 'money/expense',  'u-jpy', 'flow');

-- ===========================================
-- resource_link
--   ratio = 1 source unit あたりの target unit 数
-- ===========================================

-- Monster Energy Ruby Red (355ml / 1 pcs)
INSERT INTO resource_link (_id, source_id, target_id, ratio) VALUES
  ('rl-rr-energy',  'r-monster-rr', 'r-energy',  0),
  ('rl-rr-protein', 'r-monster-rr', 'r-protein', 0),
  ('rl-rr-fat',     'r-monster-rr', 'r-fat',     0),
  ('rl-rr-carb',    'r-monster-rr', 'r-carb',    3.195),
  ('rl-rr-salt-eq', 'r-monster-rr', 'r-salt-eq', 0.8165);

-- Monster Energy Pipeline Punch (355ml / 1 pcs)
INSERT INTO resource_link (_id, source_id, target_id, ratio) VALUES
  ('rl-pp-energy',  'r-monster-pp', 'r-energy',  195.25),
  ('rl-pp-protein', 'r-monster-pp', 'r-protein', 0),
  ('rl-pp-fat',     'r-monster-pp', 'r-fat',     0),
  ('rl-pp-carb',    'r-monster-pp', 'r-carb',    46.86),
  ('rl-pp-salt-eq', 'r-monster-pp', 'r-salt-eq', 0.5325);
