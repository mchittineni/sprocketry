CREATE TABLE IF NOT EXISTS countries (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS cities (
    id           SERIAL PRIMARY KEY,
    country_code TEXT NOT NULL REFERENCES countries (code),
    name         TEXT NOT NULL,
    latitude     DOUBLE PRECISION NOT NULL,
    longitude    DOUBLE PRECISION NOT NULL,
    UNIQUE (country_code, name)
);

INSERT INTO countries (code, name) VALUES
    ('GB', 'United Kingdom'),
    ('IN', 'India'),
    ('US', 'United States'),
    ('DE', 'Germany')
ON CONFLICT (code) DO NOTHING;

INSERT INTO cities (country_code, name, latitude, longitude) VALUES
    ('GB', 'London',     51.5074,  -0.1278),
    ('GB', 'Edinburgh',  55.9533,  -3.1883),
    ('IN', 'Hyderabad',  17.3850,  78.4867),
    ('IN', 'Bengaluru',  12.9716,  77.5946),
    ('US', 'New York',   40.7128, -74.0060),
    ('US', 'Seattle',    47.6062, -122.3321),
    ('DE', 'Berlin',     52.5200,  13.4050),
    ('DE', 'Munich',     48.1351,  11.5820)
ON CONFLICT (country_code, name) DO NOTHING;
