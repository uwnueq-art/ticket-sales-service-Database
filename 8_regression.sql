-- Автоматические регрессионные тесты (7 групп проверок логики, целостности и прав).
-- Ответственный: Сережа
-- Решенные задачи:
-- - проверены срок действия брони (15 минут), фиксация версии цены и запрет повторной брони
-- - протестированы изменение базовой цены при сохранении старой суммы брони и защита от повторной оплаты
-- - проверены возврат билета, повторный возврат, перепродажа места и автоматическая очистка просроченных броней
-- - проверены ограничения целостности БД (FK, UNIQUE) и запрет прямой записи в таблицы для роли ticket_service
-- Запускается владельцем объектов в тестовой базе после развертывания 1_schema.sql — 7_access.sql; изменения откатываются.

BEGIN;
SET LOCAL plpgsql.check_asserts = on;
DO $$
DECLARE
 u BIGINT; s BIGINT; s2 BIGINT; b BIGINT; t BIGINT; b2 BIGINT;
 p NUMERIC; v BIGINT; ep BIGINT;
BEGIN
 -- Проверка 1: создание брони, срок 15 минут и совпадение цены с версией
 SELECT id INTO STRICT u FROM users ORDER BY id LIMIT 1;
 SELECT es.id INTO STRICT s FROM event_seats es JOIN events e ON e.id=es.event_id
 WHERE es.status='available' AND e.starts_at > clock_timestamp()+interval '2 days'
 ORDER BY es.id LIMIT 1;
 b := reserve_seat(u,s);
 SELECT price_snapshot,price_version_id INTO p,v FROM bookings WHERE id=b;
 ASSERT (SELECT price FROM price_versions WHERE id=v)=p;
 ASSERT (SELECT expires_at-created_at FROM bookings WHERE id=b)=interval '15 minutes';
 RAISE NOTICE 'PASS 1: срок и версия цены';

 -- Проверка 2: отклонение повторного бронирования уже занятого места
 BEGIN
  PERFORM reserve_seat(u,s);
  RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE='FAIL: повторная бронь';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'Seat is already reserved' THEN RAISE; END IF;
 END;
 RAISE NOTICE 'PASS 2: занятое место отклонено';

 -- Проверка 3: повышение базовой цены создает новую версию, но старая бронь оплачивается по прежней сумме
 SELECT es2.id,ep1.id INTO STRICT s2,ep FROM event_seats es1
 JOIN event_seats es2 ON es2.event_id=es1.event_id AND es2.category_id=es1.category_id
 JOIN event_prices ep1 ON ep1.event_id=es1.event_id AND ep1.category_id=es1.category_id
 WHERE es1.id=s AND es2.id<>s AND es2.status='available' LIMIT 1;
 UPDATE event_prices SET base_price=base_price+100 WHERE id=ep;
 b2 := reserve_seat(u,s2);
 ASSERT (SELECT price_snapshot FROM bookings WHERE id=b2)=p+100;
 ASSERT (SELECT price_version_id FROM bookings WHERE id=b2)<>v;
 t := pay_booking(b,'reg-payment-'||b);
 ASSERT (SELECT amount FROM payments WHERE booking_id=b AND operation_type='payment')=p;
 ASSERT pay_booking(b,'reg-payment-'||b)=t;
 ASSERT (SELECT count(*) FROM tickets WHERE booking_id=b)=1;
 RAISE NOTICE 'PASS 3: новая версия, фиксация старой суммы, повтор оплаты';

 -- Проверка 4: возврат билета, повторный вызов возврата и повторная продажа места
 PERFORM refund_ticket(t,'reg-refund-'||t);
 PERFORM refund_ticket(t,'reg-refund-'||t);
 ASSERT (SELECT count(*) FROM payments WHERE booking_id=b AND operation_type='refund')=1;
 ASSERT (SELECT status FROM tickets WHERE id=t)='returned';
 b := reserve_seat(u,s);
 t := pay_booking(b,'reg-resale-'||b);
 ASSERT (SELECT count(*) FROM tickets WHERE event_seat_id=s AND status='valid')=1;
 RAISE NOTICE 'PASS 4: возврат, его повтор и повторная продажа';

 -- Проверка 5: запрет оплаты просроченной брони, очистка через expire_bookings и новая бронь
 -- Искусственно сдвигаем даты на 20 минут назад, сохраняя интервал 15 минут для CHECK
 UPDATE bookings SET created_at=CURRENT_TIMESTAMP-interval '20 minutes',
 expires_at=CURRENT_TIMESTAMP-interval '5 minutes' WHERE id=b2;
 BEGIN
  PERFORM pay_booking(b2,'reg-late-'||b2);
  RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE='FAIL: просроченная оплата';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'Booking has expired' THEN RAISE; END IF;
 END;
 PERFORM expire_bookings();
 ASSERT (SELECT status FROM bookings WHERE id=b2)='expired';
 b2 := reserve_seat(u,s2);
 RAISE NOTICE 'PASS 5: просрочка и новое бронирование';

 -- Проверка 6: срабатывание ограничений внешнего ключа и уникальности на уровне таблиц
 BEGIN
  UPDATE bookings SET price_snapshot=price_snapshot+1 WHERE id=b2;
  RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE='FAIL: неверная версия цены';
 EXCEPTION WHEN foreign_key_violation THEN NULL;
 END;
 BEGIN
  INSERT INTO event_seats(event_id,seat_id,hall_id,category_id)
  SELECT event_id,seat_id,hall_id,category_id FROM event_seats WHERE id=s;
  RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE='FAIL: дубликат места';
 EXCEPTION WHEN unique_violation THEN NULL;
 END;
 RAISE NOTICE 'PASS 6: ограничения связей и уникальности';
END $$;

-- Проверка 7: переключение на роль ticket_service — работа через функции разрешена, прямой UPDATE запрещен
SELECT set_config('test.user_id',(SELECT id::text FROM users ORDER BY id LIMIT 1),true);
SELECT set_config('test.seat_id',(SELECT es.id::text FROM event_seats es
 JOIN events e ON e.id=es.event_id WHERE es.status='available'
 AND e.starts_at>clock_timestamp() ORDER BY es.id LIMIT 1),true);
SET LOCAL ROLE ticket_service;
DO $$
DECLARE s BIGINT; b BIGINT; t BIGINT;
BEGIN
 BEGIN
  UPDATE public.event_seats SET status='sold';
  RAISE EXCEPTION SQLSTATE 'ZX001' USING MESSAGE='FAIL: прямая запись разрешена';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 s := current_setting('test.seat_id')::bigint;
 b := public.reserve_seat(current_setting('test.user_id')::bigint,s);
 t := public.pay_booking(b,'role-pay-'||b);
 PERFORM public.refund_ticket(t,'role-refund-'||t);
 RAISE NOTICE 'PASS 7: API доступен, прямое изменение запрещено';
END $$;
RESET ROLE;
ROLLBACK;