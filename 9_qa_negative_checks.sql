-- Расширенный сценарий проверки негативных кейсов, целостности модели и прав доступа.
-- Ответственный: Сергей
-- Решенные задачи:
-- - реализована проверка динамического ценообразования (+20% менее чем за 24 часа до начала события)
-- - добавлены негативные кейсы с NULL, несуществующими ID и конфликтами ключей операций (operation_key)
-- - проверен запрет бронирования и возврата после начала события, а также целостность модели (email, CHECK, составной FK)
-- - проверена корректность отчетов (event_occupancy, sales_operations) и изоляция прав ролей ticket_reporter, ticket_maintenance, ticket_service
-- - настроено автоматическое откатывание всех тестовых изменений в конце скрипта (ROLLBACK)
-- Запускается на базе после развертывания 1_schema.sql — 7_access.sql и заполнения тестовыми данными.

BEGIN;
SET LOCAL plpgsql.check_asserts = on;

-- Проверяем динамическую наценку +20% для события менее чем за 24 часа до начала
DO $$
DECLARE
    u BIGINT;
    es_soon BIGINT;
    base_p NUMERIC(12,2);
    b_soon BIGINT;
BEGIN
    SELECT id INTO STRICT u FROM public.users ORDER BY id LIMIT 1;
    SELECT es.id, ep.base_price INTO STRICT es_soon, base_p
    FROM public.event_seats es
    JOIN public.events e ON e.id = es.event_id
    JOIN public.event_prices ep ON ep.event_id = es.event_id AND ep.category_id = es.category_id
    WHERE es.status = 'available'
      AND e.starts_at > clock_timestamp()
      AND e.starts_at <= clock_timestamp() + INTERVAL '24 hours'
    ORDER BY es.id LIMIT 1;

    b_soon := public.reserve_seat(u, es_soon);
    ASSERT (SELECT price_snapshot FROM public.bookings WHERE id = b_soon) = round(base_p * 1.20, 2),
        'Ожидалась наценка +20% для события менее чем за 24 часа';
    RAISE NOTICE 'QA PASS 1: динамическая наценка +20%% (итого %)', round(base_p * 1.20, 2);
END $$;

-- Проверяем отказ при NULL, несуществующих ID и конфликтах ключа операции
DO $$
DECLARE
    u BIGINT; s BIGINT; b BIGINT; t BIGINT;
BEGIN
    -- Берем первого покупателя и свободное место на событие через 2+ дня
    SELECT id INTO STRICT u FROM public.users ORDER BY id LIMIT 1;
    SELECT es.id INTO STRICT s FROM public.event_seats es
    JOIN public.events e ON e.id = es.event_id
    WHERE es.status = 'available' AND e.starts_at > clock_timestamp() + INTERVAL '2 days'
    ORDER BY es.id LIMIT 1;

    -- Проверяем передачу NULL покупателя и несуществующего места
    BEGIN
        PERFORM public.reserve_seat(NULL, s);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: принят NULL user_id';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Buyer does not exist' THEN RAISE; END IF;
    END;

    BEGIN
        PERFORM public.reserve_seat(u, -999);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: принят несуществующий event_seat_id';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Event seat does not exist' THEN RAISE; END IF;
    END;

    -- Проверяем отказ при пустом или NULL ключе операции
    b := public.reserve_seat(u, s);
    BEGIN
        PERFORM public.pay_booking(b, NULL);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: принят NULL operation_key';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Operation key required' THEN RAISE; END IF;
    END;

    BEGIN
        PERFORM public.pay_booking(b, '   ');
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: принят пустой operation_key';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Operation key required' THEN RAISE; END IF;
    END;

    t := public.pay_booking(b, 'qa-op-key-1');

    -- Проверяем запрет использования ключа оплаты для возврата
    BEGIN
        PERFORM public.refund_ticket(t, 'qa-op-key-1');
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: принят конфликт operation_key';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Operation key conflict' THEN RAISE; END IF;
    END;

    -- Проверяем запрет повторной оплаты уже оплаченной брони новым ключом
    BEGIN
        PERFORM public.pay_booking(b, 'qa-op-key-2');
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: повторная оплата новым ключом';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Booking is not active' THEN RAISE; END IF;
    END;

    -- Проверяем запрет повторного возврата билета новым ключом
    PERFORM public.refund_ticket(t, 'qa-refund-key-1');
    BEGIN
        PERFORM public.refund_ticket(t, 'qa-refund-key-2');
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: повторный возврат новым ключом';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Ticket is not valid' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'QA PASS 2: NULL, несуществующие ID и конфликты operation_key отклонены';
END $$;

-- Проверяем запрет бронирования и возврата после начала события
DO $$
DECLARE
    u BIGINT; h BIGINT; e_past BIGINT; es_past BIGINT;
    b_act BIGINT; t_act BIGINT;
BEGIN
    SELECT id INTO STRICT u FROM public.users ORDER BY id LIMIT 1;
    SELECT id INTO STRICT h FROM public.halls ORDER BY id LIMIT 1;

    -- Создаем событие, оформляем билет и переводим время начала в прошлое
    INSERT INTO public.events(hall_id, name, starts_at)
    VALUES (h, 'QA Начавшееся событие', clock_timestamp() + INTERVAL '1 hour')
    RETURNING id INTO e_past;

    INSERT INTO public.event_prices(event_id, category_id, base_price)
    SELECT e_past, id, 500.00 FROM public.seat_categories;

    INSERT INTO public.event_seats(event_id, seat_id, hall_id, category_id)
    SELECT e_past, s.id, h, s.category_id FROM public.seats s WHERE s.hall_id = h LIMIT 2;

    SELECT id INTO STRICT es_past FROM public.event_seats WHERE event_id = e_past ORDER BY id LIMIT 1;
    b_act := public.reserve_seat(u, es_past);
    t_act := public.pay_booking(b_act, 'qa-past-pay-' || b_act);

    UPDATE public.events SET starts_at = clock_timestamp() - INTERVAL '1 minute' WHERE id = e_past;

    -- Проверяем отказ возврата и новой брони после начала мероприятия
    BEGIN
        PERFORM public.refund_ticket(t_act, 'qa-past-refund-' || t_act);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: возврат после начала события разрешен';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Refund after event start is forbidden' THEN RAISE; END IF;
    END;

    SELECT id INTO STRICT es_past FROM public.event_seats WHERE event_id = e_past AND status = 'available' LIMIT 1;
    BEGIN
        PERFORM public.reserve_seat(u, es_past);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: бронь после начала события разрешена';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Event has already started' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'QA PASS 3: бронь и возврат после начала события заблокированы';
END $$;

-- Проверяем ограничения целостности модели
DO $$
DECLARE
    v BIGINT; h1 BIGINT; h2 BIGINT; c1 BIGINT; s_other BIGINT; e1 BIGINT;
BEGIN
    SELECT id INTO STRICT v FROM public.venues ORDER BY id LIMIT 1;
    SELECT id INTO STRICT h1 FROM public.halls ORDER BY id LIMIT 1;
    SELECT id INTO STRICT c1 FROM public.seat_categories ORDER BY id LIMIT 1;
    SELECT id INTO STRICT e1 FROM public.events ORDER BY id LIMIT 1;

    -- Проверяем регистронезависимую уникальность email
    BEGIN
        INSERT INTO public.users(name, email) VALUES ('Дубль', 'ANNA@example.test');
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: дубль email в другом регистре';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    -- Проверяем запрет NULL в обязательном поле venues.name
    BEGIN
        INSERT INTO public.venues(name, address) VALUES (NULL, 'Адрес');
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: NULL в обязательном поле name';
    EXCEPTION WHEN not_null_violation THEN NULL;
    END;

    -- Проверяем ограничения CHECK на отрицательную цену и нулевой ряд
    BEGIN
        INSERT INTO public.event_prices(event_id, category_id, base_price) VALUES (e1, c1, -10);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: отрицательная цена';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        INSERT INTO public.seats(hall_id, category_id, row_number, seat_number) VALUES (h1, c1, 0, 1);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: ряд 0 разрешен';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    -- Проверяем составной FK: место из другого зала нельзя привязать к событию
    INSERT INTO public.halls(venue_id, name) VALUES (v, 'QA Второй зал') RETURNING id INTO h2;
    INSERT INTO public.seats(hall_id, category_id, row_number, seat_number) VALUES (h2, c1, 1, 1) RETURNING id INTO s_other;
    BEGIN
        INSERT INTO public.event_seats(event_id, seat_id, hall_id, category_id) VALUES (e1, s_other, h1, c1);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: место из чужого зала привязано';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;

    RAISE NOTICE 'QA PASS 4: целостность модели (email, NOT NULL, CHECK, составной FK зала и места)';
END $$;

-- Проверяем корректность представлений отчетности
DO $$
DECLARE
    u BIGINT; s BIGINT; b BIGINT; t BIGINT;
    occ RECORD;
    net_sum NUMERIC;
BEGIN
    SELECT id INTO STRICT u FROM public.users ORDER BY id LIMIT 1;
    SELECT es.id INTO STRICT s FROM public.event_seats es
    JOIN public.events e ON e.id = es.event_id
    WHERE es.status = 'available' AND e.starts_at > clock_timestamp() + INTERVAL '2 days'
    ORDER BY es.id LIMIT 1;

    b := public.reserve_seat(u, s);
    t := public.pay_booking(b, 'qa-rep-pay-' || b);
    SELECT * INTO occ FROM public.event_occupancy
    WHERE event_id = (SELECT event_id FROM public.event_seats WHERE id = s);
    ASSERT occ.sold_seats >= 1, 'Ожидалось sold_seats >= 1';

    PERFORM public.refund_ticket(t, 'qa-rep-ref-' || t);
    SELECT coalesce(sum(net_amount), 0) INTO net_sum FROM public.sales_operations
    WHERE event_id = (SELECT event_id FROM public.event_seats WHERE id = s);
    ASSERT net_sum = 0, 'Ожидалась нулевая чистая выручка после полного возврата';

    RAISE NOTICE 'QA PASS 5: отчеты event_occupancy и sales_operations корректны';
END $$;

-- Проверяем изоляцию прав всех трех ролей
SET LOCAL ROLE ticket_reporter;
DO $$
DECLARE cnt BIGINT;
BEGIN
    SELECT count(*) INTO cnt FROM public.event_occupancy;
    SELECT count(*) INTO cnt FROM public.sales_operations;
    SELECT count(*) INTO cnt FROM public.price_history;

    BEGIN
        PERFORM count(*) FROM public.users;
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: ticket_reporter читает users';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    BEGIN
        PERFORM public.reserve_seat(1, 1);
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: ticket_reporter вызвал reserve_seat';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    RAISE NOTICE 'QA PASS 6a: права роли ticket_reporter изолированы';
END $$;
RESET ROLE;

SET LOCAL ROLE ticket_maintenance;
DO $$
BEGIN
    PERFORM public.expire_bookings();
    BEGIN
        PERFORM count(*) FROM public.users;
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: ticket_maintenance читает users';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM public.pay_booking(1, 'k1');
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: ticket_maintenance вызвал pay_booking';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'QA PASS 6b: права роли ticket_maintenance изолированы';
END $$;
RESET ROLE;

SET LOCAL ROLE ticket_service;
DO $$
BEGIN
    BEGIN
        PERFORM public.expire_bookings();
        RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE = 'FAIL: ticket_service вызвал expire_bookings';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'QA PASS 6c: права роли ticket_service изолированы';
END $$;
RESET ROLE;

ROLLBACK;

