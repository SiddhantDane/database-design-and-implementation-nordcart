-- MySQL: Transforming Business Operations with Database Technologies
-- Schema: NordCart (fictional e-commerce operational database)

DROP DATABASE IF EXISTS nordcart;
CREATE DATABASE nordcart;
USE nordcart;

-- ========================
-- DDL: Core entities
-- ========================
CREATE TABLE customers (
  customer_id INT AUTO_INCREMENT PRIMARY KEY,
  full_name   VARCHAR(120) NOT NULL,
  email       VARCHAR(160) NOT NULL UNIQUE,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE products (
  product_id   INT AUTO_INCREMENT PRIMARY KEY,
  sku          VARCHAR(40) NOT NULL UNIQUE,
  product_name VARCHAR(140) NOT NULL,
  unit_price   DECIMAL(10,2) NOT NULL CHECK (unit_price >= 0),
  is_active    BOOLEAN NOT NULL DEFAULT TRUE
) ENGINE=InnoDB;

CREATE TABLE inventory (
  product_id INT PRIMARY KEY,
  on_hand    INT NOT NULL CHECK (on_hand >= 0),
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_inventory_product
    FOREIGN KEY (product_id) REFERENCES products(product_id)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE orders (
  order_id     BIGINT AUTO_INCREMENT PRIMARY KEY,
  customer_id  INT NOT NULL,
  order_status ENUM('PENDING','PAID','SHIPPED','CANCELLED','REFUNDED') NOT NULL DEFAULT 'PENDING',
  order_total  DECIMAL(10,2) NOT NULL DEFAULT 0,
  created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_orders_customer
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX idx_orders_customer_created (customer_id, created_at)
) ENGINE=InnoDB;

CREATE TABLE order_items (
  order_item_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  order_id      BIGINT NOT NULL,
  product_id    INT NOT NULL,
  quantity      INT NOT NULL CHECK (quantity > 0),
  unit_price    DECIMAL(10,2) NOT NULL CHECK (unit_price >= 0),
  CONSTRAINT fk_items_order
    FOREIGN KEY (order_id) REFERENCES orders(order_id)
    ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_items_product
    FOREIGN KEY (product_id) REFERENCES products(product_id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  UNIQUE KEY uk_order_product (order_id, product_id)
) ENGINE=InnoDB;

CREATE TABLE payments (
  payment_id  BIGINT AUTO_INCREMENT PRIMARY KEY,
  order_id    BIGINT NOT NULL,
  amount      DECIMAL(10,2) NOT NULL CHECK (amount >= 0),
  method      ENUM('CARD','PAYPAL','BANK_TRANSFER') NOT NULL,
  paid_at     DATETIME NULL,
  status      ENUM('INITIATED','CONFIRMED','FAILED','REFUNDED') NOT NULL DEFAULT 'INITIATED',
  CONSTRAINT fk_payments_order
    FOREIGN KEY (order_id) REFERENCES orders(order_id)
    ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX idx_payments_order (order_id, status)
) ENGINE=InnoDB;

CREATE TABLE stock_movements (
  movement_id BIGINT AUTO_INCREMENT PRIMARY KEY,
  product_id  INT NOT NULL,
  change_qty  INT NOT NULL,
  reason      ENUM('SALE','RESTOCK','ADJUSTMENT','REFUND') NOT NULL,
  reference_id BIGINT NULL,
  moved_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_moves_product
    FOREIGN KEY (product_id) REFERENCES products(product_id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX idx_moves_product_time (product_id, moved_at)
) ENGINE=InnoDB;

-- ========================
-- DML: Seed sample data
-- ========================

INSERT INTO customers (full_name, email) VALUES
('Siddhant Dane','siddhant@gmail.com'),
('Rishikesh Aher','rishikesh@gmail.com'),
('Smit Pandit','smit@gmail.com');

INSERT INTO products (sku, product_name, unit_price) VALUES
('NC-USB-C-01','USB-C Cable 1m', 9.99),
('NC-SSD-01','1TB NVMe SSD', 89.00),
('NC-MOUSE-01','Wireless Mouse', 24.50),
('NC-KB-01','Mechanical Keyboard', 79.90);

INSERT INTO inventory (product_id, on_hand)
SELECT product_id,
       CASE sku
         WHEN 'NC-USB-C-01' THEN 200
         WHEN 'NC-SSD-01'   THEN 40
         WHEN 'NC-MOUSE-01' THEN 120
         WHEN 'NC-KB-01'    THEN 50
       END AS on_hand
FROM products;

-- ========================
-- Transaction: Place an order safely
-- ========================
-- Scenario: customer 1 buys 2x USB-C cable and 1x SSD.
-- This transaction:
-- 1) creates an order
-- 2) inserts order items with current prices
-- 3) checks and decrements inventory with row locks to prevent overselling
-- 4) records a payment
-- 5) updates the order total and status

START TRANSACTION;

INSERT INTO orders (customer_id) VALUES (1);
SET @new_order_id = LAST_INSERT_ID();

-- Lock inventory rows for items being purchased
SELECT product_id, on_hand
FROM inventory
WHERE product_id IN ( (SELECT product_id FROM products WHERE sku='NC-USB-C-01'),
                      (SELECT product_id FROM products WHERE sku='NC-SSD-01') )
FOR UPDATE;

-- Insert items
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT @new_order_id, p.product_id, 2, p.unit_price
FROM products p WHERE p.sku='NC-USB-C-01';

INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT @new_order_id, p.product_id, 1, p.unit_price
FROM products p WHERE p.sku='NC-SSD-01';

-- Decrement inventory
UPDATE inventory i
JOIN products p ON p.product_id = i.product_id
SET i.on_hand = i.on_hand - 2
WHERE p.sku='NC-USB-C-01' AND i.on_hand >= 2;

UPDATE inventory i
JOIN products p ON p.product_id = i.product_id
SET i.on_hand = i.on_hand - 1
WHERE p.sku='NC-SSD-01' AND i.on_hand >= 1;

-- Record stock movements
INSERT INTO stock_movements (product_id, change_qty, reason, reference_id)
SELECT product_id, -2, 'SALE', @new_order_id FROM products WHERE sku='NC-USB-C-01';
INSERT INTO stock_movements (product_id, change_qty, reason, reference_id)
SELECT product_id, -1, 'SALE', @new_order_id FROM products WHERE sku='NC-SSD-01';

-- Compute order total
UPDATE orders o
JOIN (
  SELECT order_id, ROUND(SUM(quantity * unit_price),2) AS total
  FROM order_items
  WHERE order_id = @new_order_id
  GROUP BY order_id
) t ON t.order_id = o.order_id
SET o.order_total = t.total;

-- Payment
INSERT INTO payments (order_id, amount, method, paid_at, status)
SELECT @new_order_id, order_total, 'CARD', NOW(), 'CONFIRMED'
FROM orders WHERE order_id = @new_order_id;

UPDATE orders SET order_status='PAID' WHERE order_id = @new_order_id;

COMMIT;

-- ========================
-- Reporting Queries (screenshots)
-- ========================

-- 1) Order summary for customer service
SELECT o.order_id, c.full_name, o.order_status, o.order_total, o.created_at
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
ORDER BY o.created_at DESC;

-- 2) Line-item detail for a single order
SELECT oi.order_id, p.sku, p.product_name, oi.quantity, oi.unit_price,
       ROUND(oi.quantity * oi.unit_price,2) AS line_total
FROM order_items oi
JOIN products p ON p.product_id = oi.product_id
WHERE oi.order_id = @new_order_id;

-- 3) Low-stock alert
SELECT p.sku, p.product_name, i.on_hand
FROM inventory i
JOIN products p ON p.product_id = i.product_id
WHERE i.on_hand < 50
ORDER BY i.on_hand ASC;

-- 4) Top products by revenue
SELECT p.sku, p.product_name,
       ROUND(SUM(oi.quantity * oi.unit_price),2) AS revenue
FROM order_items oi
JOIN products p ON p.product_id = oi.product_id
GROUP BY p.product_id, p.sku, p.product_name
ORDER BY revenue DESC;

-- 5) Payments reconciliation
SELECT o.order_id, o.order_total, pay.amount, pay.method, pay.status, pay.paid_at
FROM orders o
JOIN payments pay ON pay.order_id = o.order_id
ORDER BY pay.paid_at DESC;
