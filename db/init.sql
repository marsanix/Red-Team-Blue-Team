-- init.sql dijalankan OTOMATIS oleh image mysql hanya saat volume data masih
-- kosong (first boot). Database itu sendiri dibuat via env MYSQL_DATABASE.
--
-- Catatan: tabel `users` dibuat oleh SQLAlchemy (db.create_all) di backend;
-- tabel `customers` dibuat di sini beserta data sampel.

CREATE TABLE IF NOT EXISTS customers (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(120) NOT NULL,
    email      VARCHAR(120) NOT NULL,
    phone      VARCHAR(30),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO customers (name, email, phone) VALUES
    ('Marsani',                     'marsani@example.com',     '0812-0000-0001'),
    ('Muhammad Saifulloh',          'saifulloh@example.com',   '0812-0000-0002'),
    ('Kristian Hananiel Hura',      'kristian@example.com',    '0812-0000-0003'),
    ('Sukandar',                    'sukandar@example.com',    '0812-0000-0004');
