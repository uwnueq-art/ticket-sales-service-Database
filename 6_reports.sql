-- Представления и контрольные запросы для отчетности по продажам, заполняемости залов и ценам.
-- Ответственный: Алексей
-- Решенные задачи:
-- - создано представление event_occupancy для подсчета свободных, забронированных и проданных мест по событиям
-- - создано представление sales_operations для учета успешных оплат, возвратов и чистой выручки
-- - создано представление price_history для просмотра истории зафиксированных цен по категориям
-- - добавлены тестовые SELECT-запросы для проверки отчетов и истории броней покупателя
-- Выполняется после создания схемы, данных и функций покупки.

BEGIN;

-- Заполняемость мероприятий с учетом только актуальных непросроченных броней
CREATE OR REPLACE VIEW public.event_occupancy AS
SELECT e.id AS event_id, e.name, e.starts_at,
       count(es.id) AS total_seats,
       count(es.id) FILTER (WHERE es.status = 'available' OR
           (es.status = 'reserved' AND NOT EXISTS (
               SELECT 1 FROM public.bookings b WHERE b.event_seat_id = es.id
               AND b.status = 'active' AND b.expires_at > CURRENT_TIMESTAMP
           ))) AS available_seats,
       count(es.id) FILTER (WHERE es.status = 'reserved' AND EXISTS (
           SELECT 1 FROM public.bookings b WHERE b.event_seat_id = es.id
           AND b.status = 'active' AND b.expires_at > CURRENT_TIMESTAMP
       )) AS reserved_seats,
       count(es.id) FILTER (WHERE es.status = 'sold') AS sold_seats
FROM public.events e LEFT JOIN public.event_seats es ON es.event_id = e.id
GROUP BY e.id, e.name, e.starts_at;

-- Журнал успешных денежных операций с расчетом чистой суммы (оплата с плюсом, возврат с минусом)
CREATE OR REPLACE VIEW public.sales_operations AS
SELECT p.id AS operation_id, p.created_at, e.id AS event_id, e.name AS event_name,
       p.operation_type, p.amount,
       CASE WHEN p.operation_type = 'payment' THEN p.amount ELSE -p.amount END AS net_amount
FROM public.payments p
JOIN public.bookings b ON b.id = p.booking_id
JOIN public.event_seats es ON es.id = b.event_seat_id
JOIN public.events e ON e.id = es.event_id
WHERE p.status = 'success';

-- История зафиксированных цен при бронировании в разрезе событий и категорий мест
CREATE OR REPLACE VIEW public.price_history AS
SELECT v.id AS version_id, e.name AS event_name, c.name AS category,
 v.price, v.created_at
FROM public.price_versions v
JOIN public.event_prices ep ON ep.id = v.event_price_id
JOIN public.events e ON e.id = ep.event_id
JOIN public.seat_categories c ON c.id = ep.category_id;

COMMIT;

-- Проверка текущей заполняемости всех мероприятий
SELECT * FROM public.event_occupancy ORDER BY starts_at;

-- Сводка продаж и возвратов по событиям за выбранный период
SELECT event_id, event_name,
       count(*) FILTER (WHERE operation_type = 'payment') AS purchases,
       count(*) FILTER (WHERE operation_type = 'refund') AS refunds,
       coalesce(sum(amount) FILTER (WHERE operation_type = 'payment'), 0) AS received,
       coalesce(sum(amount) FILTER (WHERE operation_type = 'refund'), 0) AS returned,
       sum(net_amount) AS net_receipts
FROM public.sales_operations
WHERE created_at >= TIMESTAMPTZ '2026-11-01 00:00:00+03'
  AND created_at < TIMESTAMPTZ '2026-12-01 00:00:00+03'
GROUP BY event_id, event_name ORDER BY event_id;

-- История бронирований и билетов конкретного покупателя
SELECT b.id AS booking_id, e.name, s.row_number, s.seat_number,
       b.price_snapshot, b.status AS booking_status,
       t.ticket_number, t.status AS ticket_status
FROM public.bookings b
JOIN public.event_seats es ON es.id = b.event_seat_id
JOIN public.events e ON e.id = es.event_id
JOIN public.seats s ON s.id = es.seat_id
LEFT JOIN public.tickets t ON t.booking_id = b.id
WHERE b.user_id = 1 ORDER BY b.created_at DESC;