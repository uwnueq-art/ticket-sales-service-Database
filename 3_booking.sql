-- Функции бронирования места и очистки просроченных броней.
-- Ответственный: Алексей
-- Решенные задачи:
-- - реализована функция reserve_seat с блокировкой места и проверкой актуального статуса
-- - добавлен расчет цены с наценкой 20% менее чем за 24 часа до начала события и записью версии цены
-- - реализована функция expire_bookings для снятия просроченных броней без блокировки активных запросов
-- - закрыт прямой публичный вызов функций (REVOKE FROM PUBLIC)
-- Выполняется после создания схемы и наполнения базовыми данными.

BEGIN;

-- Бронирование одного места на 15 минут с фиксацией текущей цены
CREATE OR REPLACE FUNCTION public.reserve_seat(
    p_user_id BIGINT, p_event_seat_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_seat public.event_seats%ROWTYPE;
    v_start TIMESTAMPTZ;
    v_now TIMESTAMPTZ;
    v_price NUMERIC(12,2);
    v_booking BIGINT;
    v_price_id BIGINT;
    v_version BIGINT;
    v_old_price NUMERIC(12,2);
BEGIN
    PERFORM 1 FROM public.users WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Buyer does not exist'; END IF;

    -- Блокируем строку места от параллельных запросов
    SELECT * INTO v_seat FROM public.event_seats
    WHERE id = p_event_seat_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Event seat does not exist'; END IF;

    v_now := clock_timestamp();
    SELECT starts_at INTO v_start FROM public.events WHERE id = v_seat.event_id;
    IF v_start <= v_now THEN RAISE EXCEPTION 'Event has already started'; END IF;

    -- Переводим старую активную бронь в expired, если ее срок уже вышел
    UPDATE public.bookings SET status = 'expired'
    WHERE event_seat_id = p_event_seat_id
      AND status = 'active' AND expires_at <= v_now;

    IF v_seat.status = 'sold' OR EXISTS (
        SELECT 1 FROM public.tickets
        WHERE event_seat_id = p_event_seat_id AND status = 'valid'
    ) THEN RAISE EXCEPTION 'Seat has been sold'; END IF;
    IF EXISTS (
        SELECT 1 FROM public.bookings
        WHERE event_seat_id = p_event_seat_id AND status = 'active'
    ) THEN RAISE EXCEPTION 'Seat is already reserved'; END IF;

    SELECT id, base_price INTO STRICT v_price_id, v_price FROM public.event_prices
    WHERE event_id = v_seat.event_id AND category_id = v_seat.category_id FOR UPDATE;

    -- Повторно сверяем время после ожидания блокировки и считаем наценку за сутки
    v_now := clock_timestamp();
    IF v_start <= v_now THEN RAISE EXCEPTION 'Event has already started'; END IF;
    IF v_start <= v_now + INTERVAL '24 hours' THEN
        v_price := round(v_price * 1.20, 2);
    END IF;

    -- Записываем новую версию цены, если сумма изменилась с момента прошлой брони
    SELECT id, price INTO v_version, v_old_price FROM public.price_versions
    WHERE event_price_id = v_price_id ORDER BY id DESC LIMIT 1;
    IF v_version IS NULL OR v_old_price <> v_price THEN
        INSERT INTO public.price_versions(event_price_id, price)
        VALUES (v_price_id, v_price) RETURNING id INTO v_version;
    END IF;

    INSERT INTO public.bookings(user_id, event_seat_id, created_at,
                               expires_at, price_snapshot, price_version_id)
    VALUES (p_user_id, p_event_seat_id, v_now,
            v_now + INTERVAL '15 minutes', v_price, v_version)
    RETURNING id INTO v_booking;
    UPDATE public.event_seats SET status = 'reserved' WHERE id = p_event_seat_id;
    RETURN v_booking;
END;
$$;

-- Фоновая очистка истекших броней и возврат мест в продажу
CREATE OR REPLACE FUNCTION public.expire_bookings()
RETURNS INTEGER LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_seat BIGINT;
    v_count INTEGER := 0;
    v_changed INTEGER;
BEGIN
    -- Берем только свободные от блокировок места (SKIP LOCKED), чтобы не мешать оплате
    FOR v_seat IN
        SELECT es.id FROM public.event_seats es
        WHERE EXISTS (SELECT 1 FROM public.bookings b
            WHERE b.event_seat_id = es.id AND b.status = 'active'
              AND b.expires_at <= clock_timestamp())
        ORDER BY es.id FOR UPDATE OF es SKIP LOCKED
    LOOP
        UPDATE public.bookings SET status = 'expired'
        WHERE event_seat_id = v_seat AND status = 'active'
          AND expires_at <= clock_timestamp();
        GET DIAGNOSTICS v_changed = ROW_COUNT;
        v_count := v_count + v_changed;
        IF v_changed > 0 THEN
            UPDATE public.event_seats SET status = 'available'
            WHERE id = v_seat AND status = 'reserved'
              AND NOT EXISTS (SELECT 1 FROM public.bookings
                  WHERE event_seat_id = v_seat AND status = 'active')
              AND NOT EXISTS (SELECT 1 FROM public.tickets
                  WHERE event_seat_id = v_seat AND status = 'valid');
        END IF;
    END LOOP;
    RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.reserve_seat(BIGINT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expire_bookings() FROM PUBLIC;
COMMIT;