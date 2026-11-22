-- Функции оплаты брони и возврата билета.
-- Ответственный: Алексей
-- Решенные задачи:
-- - реализована функция pay_booking для атомарной оплаты брони, выпуска билета и смены статусов
-- - реализована функция refund_ticket для полного возврата средств до начала события и возврата места в продажу
-- - настроена защита от повторного списания и дублей по ключу операции (advisory lock + operation_key)
-- - закрыт прямой публичный вызов функций (REVOKE FROM PUBLIC)
-- Выполняется после создания схемы, данных и функций бронирования.

BEGIN;

-- Оплата активной брони и выпуск билета по ключу операции
CREATE OR REPLACE FUNCTION public.pay_booking(p_booking_id BIGINT, p_key TEXT)
RETURNS BIGINT LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    b public.bookings%ROWTYPE;
    op public.payments%ROWTYPE;
    v_seat_id BIGINT;
    result_id BIGINT;
    moment TIMESTAMPTZ;
BEGIN
    IF p_key IS NULL OR btrim(p_key) = '' THEN RAISE EXCEPTION 'Operation key required'; END IF;
    -- Блокируем параллельные запросы с одинаковым ключом операции
    PERFORM pg_advisory_xact_lock(hashtextextended(p_key, 0));
    SELECT event_seat_id INTO v_seat_id FROM public.bookings WHERE id = p_booking_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found'; END IF;
    PERFORM 1 FROM public.event_seats WHERE id = v_seat_id FOR UPDATE;
    SELECT * INTO b FROM public.bookings WHERE id = p_booking_id FOR UPDATE;

    -- Если ключ уже использовался, возвращаем ID ранее выпущенного билета
    SELECT * INTO op FROM public.payments WHERE operation_key = p_key;
    IF FOUND THEN
        IF op.booking_id <> p_booking_id OR op.operation_type <> 'payment'
           OR op.status <> 'success' THEN RAISE EXCEPTION 'Operation key conflict'; END IF;
        SELECT id INTO STRICT result_id FROM public.tickets WHERE booking_id = b.id;
        RETURN result_id;
    END IF;

    -- Проверяем актуальное время и статусы после снятия блокировки
    moment := clock_timestamp();
    IF b.status <> 'active' THEN RAISE EXCEPTION 'Booking is not active'; END IF;
    IF b.expires_at <= moment THEN RAISE EXCEPTION 'Booking has expired'; END IF;
    IF EXISTS (SELECT 1 FROM public.events e JOIN public.event_seats es ON es.event_id = e.id
        WHERE es.id = v_seat_id AND e.starts_at <= moment) THEN
        RAISE EXCEPTION 'Event has already started';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.event_seats WHERE id = v_seat_id AND status = 'reserved') THEN
        RAISE EXCEPTION 'Seat is not reserved';
    END IF;

    INSERT INTO public.payments(booking_id, operation_type, status, amount, operation_key, created_at)
    VALUES (b.id, 'payment', 'success', b.price_snapshot, p_key, moment);
    INSERT INTO public.tickets(booking_id, event_seat_id, ticket_number, issued_at)
    VALUES (b.id, v_seat_id, 'TICKET-' || b.id::TEXT, moment) RETURNING id INTO result_id;
    UPDATE public.bookings SET status = 'paid' WHERE id = b.id;
    UPDATE public.event_seats SET status = 'sold' WHERE id = v_seat_id;
    RETURN result_id;
END;
$$;

-- Возврат действующего билета до начала события и освобождение места
CREATE OR REPLACE FUNCTION public.refund_ticket(p_ticket_id BIGINT, p_key TEXT)
RETURNS BIGINT LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    t public.tickets%ROWTYPE;
    b public.bookings%ROWTYPE;
    op public.payments%ROWTYPE;
    v_seat_id BIGINT;
    result_id BIGINT;
    moment TIMESTAMPTZ;
BEGIN
    IF p_key IS NULL OR btrim(p_key) = '' THEN RAISE EXCEPTION 'Operation key required'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(p_key, 0));
    SELECT event_seat_id INTO v_seat_id FROM public.tickets WHERE id = p_ticket_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Ticket not found'; END IF;
    PERFORM 1 FROM public.event_seats WHERE id = v_seat_id FOR UPDATE;
    SELECT * INTO t FROM public.tickets WHERE id = p_ticket_id;
    SELECT * INTO b FROM public.bookings WHERE id = t.booking_id FOR UPDATE;
    SELECT * INTO t FROM public.tickets WHERE id = p_ticket_id FOR UPDATE;

    -- Повторный возврат с тем же ключом возвращает ID прежней операции
    SELECT * INTO op FROM public.payments WHERE operation_key = p_key;
    IF FOUND THEN
        IF op.booking_id <> b.id OR op.operation_type <> 'refund'
           OR op.status <> 'success' THEN RAISE EXCEPTION 'Operation key conflict'; END IF;
        RETURN op.id;
    END IF;

    -- Проверяем валидность билета и что мероприятие еще не началось
    moment := clock_timestamp();
    IF t.status <> 'valid' THEN RAISE EXCEPTION 'Ticket is not valid'; END IF;
    IF EXISTS (SELECT 1 FROM public.events e JOIN public.event_seats es ON es.event_id = e.id
        WHERE es.id = v_seat_id AND e.starts_at <= moment) THEN
        RAISE EXCEPTION 'Refund after event start is forbidden';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.payments WHERE booking_id = b.id
        AND operation_type = 'payment' AND status = 'success' AND amount = b.price_snapshot) THEN
        RAISE EXCEPTION 'Successful matching payment not found';
    END IF;

    INSERT INTO public.payments(booking_id, operation_type, status, amount, operation_key, created_at)
    VALUES (b.id, 'refund', 'success', b.price_snapshot, p_key, moment) RETURNING id INTO result_id;
    UPDATE public.tickets SET status = 'returned', returned_at = moment WHERE id = t.id;
    UPDATE public.event_seats SET status = 'available' WHERE id = v_seat_id;
    RETURN result_id;
END;
$$;

REVOKE ALL ON FUNCTION public.pay_booking(BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refund_ticket(BIGINT, TEXT) FROM PUBLIC;
COMMIT;