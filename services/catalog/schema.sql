CREATE TABLE IF NOT EXISTS products (
    sku         TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT NOT NULL,
    category    TEXT NOT NULL,
    price       NUMERIC(10, 2) NOT NULL,
    stock       INTEGER NOT NULL DEFAULT 0
);

INSERT INTO products (sku, name, description, category, price, stock) VALUES
    ('RB-001', 'Cargo Bot',      'Heavy-lift warehouse robot',          'industrial', 1299.00, 12),
    ('RB-002', 'Sweep Bot',      'Autonomous floor cleaner',            'home',        349.00, 40),
    ('RB-003', 'Garden Bot',     'Weeds, waters and mows on schedule',  'home',        599.00, 25),
    ('RB-004', 'Drone Courier',  'Last-mile parcel delivery drone',     'logistics',   899.00,  8),
    ('RB-005', 'Arm Kit',        'Six-axis desktop robotic arm',        'maker',       249.00, 60),
    ('RB-006', 'Sentinel',       'Perimeter security patrol unit',      'industrial', 1899.00,  0)
ON CONFLICT (sku) DO NOTHING;
