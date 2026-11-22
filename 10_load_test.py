"""Нагрузочный тест конкурентной покупки одного места через pgbench (1000 попыток: 20 клиентов x 50 транзакций).
Ответственный: Сережа
Решенные задачи:
- реализовано создание изолированной тестовой схемы и одного тестового места на новое событие
- настроена многопоточная нагрузка через pgbench с одновременным бронированием и оплатой (reserve_seat + pay_booking)
- добавлена итоговая проверка целостности (ровно 1 действующий билет и 1 успешная оплата при 999 ожидаемых отказах)
Запускать только в отдельной тестовой базе! Нужны Python 3 и утилиты psql/pgbench в PATH или через --bin.
Пароль передается штатным файлом pgpass, а не параметром командной строки.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--database',required=True)
p.add_argument('--host',default='localhost')
p.add_argument('--port',default='5432')
p.add_argument('--user',required=True)
p.add_argument('--bin',default='')
p.add_argument('--clients',type=int,default=20)
p.add_argument('--transactions',type=int,default=50)
a=p.parse_args()
if min(a.clients,a.transactions)<1: p.error('Число клиентов и транзакций должно быть положительным')
env=dict(os.environ,PGCLIENTENCODING='UTF8')
conn=['-h',a.host,'-p',a.port,'-U',a.user,'-d',a.database]
def exe(name): return str(Path(a.bin)/name) if a.bin else name
def sql(text):
    r=subprocess.run([exe('psql'),'-X','-w','-v','ON_ERROR_STOP=1','-At',*conn],
       input=text,text=True,encoding='utf-8',capture_output=True,env=env)
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()

# Создаем изолированную схему, тестовое событие и одно место для проверки гонки клиентов
tag='qa_'+uuid.uuid4().hex[:12]
setup=f"""
BEGIN;
CREATE SCHEMA {tag};
CREATE TABLE {tag}.fixture(event_seat_id bigint, user_id bigint);
WITH e AS (
 INSERT INTO public.events(hall_id,name,starts_at)
 SELECT hall_id,'{tag}',clock_timestamp()+interval '7 days'
 FROM public.seats ORDER BY id LIMIT 1 RETURNING id,hall_id
), p AS (
 INSERT INTO public.event_prices(event_id,category_id,base_price)
 SELECT e.id,s.category_id,1000 FROM e
 JOIN LATERAL (SELECT * FROM public.seats WHERE hall_id=e.hall_id ORDER BY id LIMIT 1) s ON true
 RETURNING event_id,category_id
), es AS (
 INSERT INTO public.event_seats(event_id,seat_id,hall_id,category_id)
 SELECT p.event_id,s.id,s.hall_id,p.category_id FROM p
 JOIN LATERAL (SELECT * FROM public.seats WHERE category_id=p.category_id
 AND hall_id=(SELECT hall_id FROM e) ORDER BY id LIMIT 1) s ON true RETURNING id
)
INSERT INTO {tag}.fixture SELECT es.id,u.id FROM es
CROSS JOIN LATERAL (SELECT id FROM public.users ORDER BY id LIMIT 1) u;
CREATE FUNCTION {tag}.try_buy() RETURNS boolean LANGUAGE plpgsql AS $f$
DECLARE b bigint; s bigint; u bigint;
BEGIN
 SELECT event_seat_id,user_id INTO STRICT s,u FROM {tag}.fixture;
 b := public.reserve_seat(u,s);
 PERFORM public.pay_booking(b,'{tag}-pay-'||b);
 RETURN true;
EXCEPTION WHEN raise_exception THEN
 IF SQLERRM IN ('Seat has been sold','Seat is already reserved') THEN RETURN false; END IF;
 RAISE;
END $f$;
COMMIT;
"""
sql(setup)

# Запускаем параллельных клиентов через pgbench
with tempfile.TemporaryDirectory(prefix='ticket-load-') as d:
    script=Path(d)/'buy.sql'
    script.write_text(f'SELECT {tag}.try_buy();\n',encoding='utf-8')
    cmd=[exe('pgbench'),*conn,'-n','-c',str(a.clients),'-j',str(min(a.clients,4)),
         '-t',str(a.transactions),'-f',str(script)]
    result=subprocess.run(cmd,text=True,encoding='utf-8',capture_output=True,env=env)
    print(result.stdout)
    print(result.stderr)
    if result.returncode: raise SystemExit(result.returncode)

# Проверяем, что продан ровно 1 билет и проведена 1 успешная оплата
counts=sql(f"""SELECT
 (SELECT count(*) FROM public.tickets WHERE event_seat_id=f.event_seat_id AND status='valid'),
 (SELECT count(*) FROM public.payments p JOIN public.bookings b ON b.id=p.booking_id
  WHERE b.event_seat_id=f.event_seat_id AND p.operation_type='payment' AND p.status='success')
 FROM {tag}.fixture f;""")
if counts!='1|1': raise RuntimeError('Неверный результат: '+counts)
print('PASS: один действующий билет и одна успешная оплата.')
print(f'Попыток: {a.clients*a.transactions}, клиентов: {a.clients}. Тестовая схема: {tag}.')
print('Занятое место — ожидаемый отказ покупки, а не ошибка транзакции pgbench.')