-- Сквозной сценарий проверки полного цикла покупки, возврата и повторной брони.
-- Ответственный: Сергей
-- Решенные задачи:
-- - реализована проверка успешного бронирования места и отказа при повторной попытке занять то же место
-- - добавлена проверка оплаты брони и защита от дублирования билета при повторном запросе с тем же ключом
-- - проверен возврат билета, повторный запрос возврата и повторное бронирование освободившегося места
-- - настроено автоматическое откатывание всех тестовых изменений в конце скрипта (ROLLBACK)
-- Запускается на базе с заполненными тестовыми данными и наличием свободных мест.

BEGIN;
DO $$
DECLARE
    buyer BIGINT;
    seat BIGINT;
    booking BIGINT;
    ticket BIGINT;
    refund BIGINT;
    next_booking BIGINT;
    key_prefix TEXT := 'test-' || txid_current()::TEXT;
BEGIN
    -- Берем первого покупателя и ближайшее свободное место
    SELECT id INTO STRICT buyer FROM users ORDER BY id LIMIT 1;
    SELECT es.id INTO STRICT seat FROM event_seats es JOIN events e ON e.id = es.event_id
    WHERE es.status = 'available' AND e.starts_at > clock_timestamp()
    ORDER BY es.id LIMIT 1;

    -- Проверяем создание брони и блокировку дублирующего бронирования
    booking := reserve_seat(buyer, seat);
    BEGIN
        PERFORM reserve_seat(buyer, seat);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'Duplicate reservation accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Seat is already reserved' THEN RAISE; END IF;
    END;

    -- Проверяем оплату, повторный вызов с тем же ключом и смену статуса места
    ticket := pay_booking(booking, key_prefix || '-pay');
    IF pay_booking(booking, key_prefix || '-pay') <> ticket THEN
        RAISE EXCEPTION 'Payment retry changed ticket';
    END IF;
    IF (SELECT count(*) FROM tickets WHERE booking_id = booking) <> 1 THEN
        RAISE EXCEPTION 'Wrong ticket count';
    END IF;
    IF (SELECT status FROM event_seats WHERE id = seat) <> 'sold' THEN
        RAISE EXCEPTION 'Seat must be sold';
    END IF;

    -- Проверяем возврат билета, повторный запрос возврата и новую бронь этого же места
    refund := refund_ticket(ticket, key_prefix || '-refund');
    IF refund_ticket(ticket, key_prefix || '-refund') <> refund THEN
        RAISE EXCEPTION 'Refund retry changed operation';
    END IF;
    IF (SELECT status FROM tickets WHERE id = ticket) <> 'returned' THEN
        RAISE EXCEPTION 'Ticket must be returned';
    END IF;
    next_booking := reserve_seat(buyer, seat);
    IF next_booking = booking THEN RAISE EXCEPTION 'New booking expected'; END IF;
    RAISE NOTICE 'PASS: reservation, duplicate rejection, payment, retries, refund, rebooking';
END;
$$;
ROLLBACK;