-- Настройка ролей, прав доступа и безопасности выполнения функций.
-- Ответственный: Дана
-- Решенные задачи:
-- - созданы три групповые роли без права входа (ticket_reporter, ticket_service, ticket_maintenance)
-- - закрыто создание объектов в схеме public для всех по умолчанию (REVOKE CREATE FROM PUBLIC)
-- - переведены функции бронирования, оплаты, возврата и очистки в режим SECURITY DEFINER с безопасным search_path
-- - запрещена прямая запись в таблицы и последовательности; доступ оставлен только через функции и представления отчетов
-- Выполняется владельцем объектов с правом CREATEROLE на новой базе проекта.

BEGIN;

-- Групповые роли без паролей и права прямого входа
CREATE ROLE ticket_reporter NOLOGIN;
CREATE ROLE ticket_service NOLOGIN;
CREATE ROLE ticket_maintenance NOLOGIN;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ticket_reporter, ticket_service, ticket_maintenance;

-- Функции работают с правами владельца таблиц; pg_temp в конце защищает от подмены объектов
ALTER FUNCTION public.reserve_seat(BIGINT,BIGINT) SECURITY DEFINER;
ALTER FUNCTION public.reserve_seat(BIGINT,BIGINT) SET search_path TO pg_catalog,public,pg_temp;
ALTER FUNCTION public.pay_booking(BIGINT,TEXT) SECURITY DEFINER;
ALTER FUNCTION public.pay_booking(BIGINT,TEXT) SET search_path TO pg_catalog,public,pg_temp;
ALTER FUNCTION public.refund_ticket(BIGINT,TEXT) SECURITY DEFINER;
ALTER FUNCTION public.refund_ticket(BIGINT,TEXT) SET search_path TO pg_catalog,public,pg_temp;
ALTER FUNCTION public.expire_bookings() SECURITY DEFINER;
ALTER FUNCTION public.expire_bookings() SET search_path TO pg_catalog,public,pg_temp;

-- Запрет прямого изменения таблиц: все операции проходят только через функции
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM ticket_service, ticket_maintenance;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM ticket_service, ticket_maintenance;
REVOKE ALL ON FUNCTION public.reserve_seat(BIGINT,BIGINT),
 public.pay_booking(BIGINT,TEXT),public.refund_ticket(BIGINT,TEXT),
 public.expire_bookings() FROM PUBLIC;

-- Выдача точечных прав: сервису на операции покупки и чтение справочников, воркеру на очистку, аналитику на отчеты
GRANT EXECUTE ON FUNCTION public.reserve_seat(BIGINT,BIGINT),
 public.pay_booking(BIGINT,TEXT),public.refund_ticket(BIGINT,TEXT) TO ticket_service;
GRANT EXECUTE ON FUNCTION public.expire_bookings() TO ticket_maintenance;
GRANT SELECT ON public.events,public.venues,public.halls,public.seats,
 public.seat_categories,public.event_occupancy TO ticket_service;
GRANT SELECT ON public.event_occupancy,public.sales_operations,
 public.price_history TO ticket_reporter;

COMMIT;

-- Контрольная проверка прав (ожидается true / false / false: отчеты открыты, таблица users и прямая вставка закрыты)
SELECT has_table_privilege('ticket_reporter','public.event_occupancy','SELECT') AS can_report,
 has_table_privilege('ticket_reporter','public.users','SELECT') AS can_read_buyers,
 has_table_privilege('ticket_service','public.tickets','INSERT') AS can_insert_ticket;