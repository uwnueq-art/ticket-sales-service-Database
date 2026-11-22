-- Наполнение базы данных тестовыми записями для проверки работы сервиса.
-- Ответственный: Михаил
-- Решенные задачи:
-- - добавлены тестовая площадка, Большой зал и две категории мест (Обычная и VIP)
-- - создана схема посадки (2 ряда по 5 мест) и привязана к мероприятиям
-- - созданы два события с разным временем до начала (через 7 дней и через 12 часов) для проверки наценки 20%
-- - добавлены тестовые покупатели и контрольные запросы для проверки доступности мест и цен
-- Выполняется однократно после создания схемы базы данных.

BEGIN;

-- Тестовая площадка и зал
INSERT INTO venues(name, address)
VALUES ('Учебный концертный центр', 'Москва, Учебная улица, 1');

INSERT INTO halls(venue_id, name)
SELECT id, 'Большой зал' FROM venues;

-- Категории мест и схема рассадки (1 ряд — VIP, 2 ряд — Обычная)
INSERT INTO seat_categories(name) VALUES ('Обычная'), ('VIP');

INSERT INTO seats(hall_id, category_id, row_number, seat_number)
SELECT h.id, c.id, r.n, s.n
FROM halls h
CROSS JOIN generate_series(1, 2) AS r(n)
CROSS JOIN generate_series(1, 5) AS s(n)
JOIN seat_categories c
    ON c.name = CASE WHEN r.n = 1 THEN 'VIP' ELSE 'Обычная' END;

-- Два события для проверки обычного тарифа и наценки +20% (менее чем за 24 часа)
INSERT INTO events(hall_id, name, starts_at)
SELECT id, 'Джазовый вечер', CURRENT_TIMESTAMP + INTERVAL '7 days' FROM halls
UNION ALL
SELECT id, 'Камерный концерт', CURRENT_TIMESTAMP + INTERVAL '12 hours' FROM halls;

-- Базовые цены и привязка мест к событиям
INSERT INTO event_prices(event_id, category_id, base_price)
SELECT e.id, c.id, CASE WHEN c.name = 'VIP' THEN 2000.00 ELSE 1000.00 END
FROM events e CROSS JOIN seat_categories c;

INSERT INTO event_seats(event_id, seat_id, hall_id, category_id)
SELECT e.id, s.id, e.hall_id, s.category_id
FROM events e JOIN seats s ON s.hall_id = e.hall_id;

-- Тестовые покупатели
INSERT INTO users(name, email) VALUES
    ('Анна', 'anna@example.test'),
    ('Иван', 'ivan@example.test'),
    ('Мария', 'maria@example.test');

COMMIT;

-- Контрольная проверка количества мест и текущих цен с учетом времени до события
SELECT e.name, count(*) AS total_seats,
       count(*) FILTER (WHERE es.status = 'available') AS available_seats
FROM events e JOIN event_seats es ON es.event_id = e.id
GROUP BY e.id, e.name ORDER BY e.id;

SELECT e.name, c.name AS category, p.base_price,
       CASE WHEN e.starts_at <= CURRENT_TIMESTAMP + INTERVAL '24 hours'
            THEN round(p.base_price * 1.20, 2)
            ELSE p.base_price END AS current_price
FROM event_prices p
JOIN events e ON e.id = p.event_id
JOIN seat_categories c ON c.id = p.category_id
WHERE e.starts_at > CURRENT_TIMESTAMP
ORDER BY e.id, c.id;