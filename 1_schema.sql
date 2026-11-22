-- Схема базы данных для сервиса продажи билетов.
-- Ответственный: Михаил
-- Решенные задачи:
-- - описаны 12 основных таблиц (площадки, залы, события, цены, брони, оплаты, билеты)
-- - связаны места, залы, события и история цен
-- - добавлены проверки на уровне базы: бронь на 15 минут, одно место в одни руки, без дублей билетов и оплат
-- Выполняется однократно при развертывании пустой базы данных.
BEGIN;


-- Площадки и их адреса
CREATE TABLE venues (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    address TEXT NOT NULL
);

-- Залы внутри площадок
CREATE TABLE halls (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    venue_id BIGINT NOT NULL REFERENCES venues(id),
    name TEXT NOT NULL,
    UNIQUE (venue_id, name)
);

-- Категории мест (например, обычная и VIP)
CREATE TABLE seat_categories (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- Физические места в зале (ряд и номер не повторяются)
CREATE TABLE seats (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hall_id BIGINT NOT NULL REFERENCES halls(id),
    category_id BIGINT NOT NULL REFERENCES seat_categories(id),
    row_number INTEGER NOT NULL CHECK (row_number > 0),
    seat_number INTEGER NOT NULL CHECK (seat_number > 0),
    UNIQUE (hall_id, row_number, seat_number),
    UNIQUE (id, hall_id, category_id)
);

-- Мероприятия: привязка к залу и время начала
CREATE TABLE events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hall_id BIGINT NOT NULL REFERENCES halls(id),
    name TEXT NOT NULL,
    starts_at TIMESTAMPTZ NOT NULL,
    UNIQUE (id, hall_id)
);

-- Базовая цена для каждой категории мест на конкретное событие
CREATE TABLE event_prices (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id BIGINT NOT NULL REFERENCES events(id),
    category_id BIGINT NOT NULL REFERENCES seat_categories(id),
    base_price NUMERIC(12,2) NOT NULL CHECK (base_price >= 0),
    UNIQUE (event_id, category_id)
);

-- Места конкретного события и их текущий статус (свободно, бронь, продано)
CREATE TABLE event_seats (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id BIGINT NOT NULL,
    seat_id BIGINT NOT NULL,
    hall_id BIGINT NOT NULL,
    category_id BIGINT NOT NULL,
    status TEXT NOT NULL DEFAULT 'available'
        CHECK (status IN ('available', 'reserved', 'sold')),
    UNIQUE (event_id, seat_id),
    FOREIGN KEY (event_id, hall_id) REFERENCES events(id, hall_id),
    FOREIGN KEY (seat_id, hall_id, category_id)
        REFERENCES seats(id, hall_id, category_id),
    FOREIGN KEY (event_id, category_id)
        REFERENCES event_prices(event_id, category_id)
);

-- Покупатели (email уникален без учета регистра)
CREATE TABLE users (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT NOT NULL CHECK (btrim(email) <> '')
);
CREATE UNIQUE INDEX users_email_unique ON users (lower(email));

-- История цен, по которым бронировали билеты (старые записи не трогаем)
CREATE TABLE price_versions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_price_id BIGINT NOT NULL REFERENCES event_prices(id),
    price NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (id, price)
);
CREATE INDEX price_versions_latest ON price_versions(event_price_id, id DESC);

-- Брони актуальны ровно 15 минут и фиксируют цену на момент создания
CREATE TABLE bookings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    event_seat_id BIGINT NOT NULL REFERENCES event_seats(id),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paid', 'expired', 'cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ NOT NULL,
    price_snapshot NUMERIC(12,2) NOT NULL CHECK (price_snapshot >= 0),
    price_version_id BIGINT NOT NULL,
    FOREIGN KEY (price_version_id, price_snapshot) REFERENCES price_versions(id, price),
    CHECK (expires_at = created_at + INTERVAL '15 minutes'),
    UNIQUE (id, event_seat_id)
);
-- Защита на уровне БД: на одно место не больше одной активной брони
CREATE UNIQUE INDEX one_active_booking_per_seat
    ON bookings(event_seat_id) WHERE status = 'active';
CREATE INDEX active_booking_expiry ON bookings(expires_at) WHERE status = 'active';
CREATE INDEX bookings_by_user ON bookings(user_id, created_at DESC);

-- Денежные операции (оплата и возврат) с ключом защиты от повторного списания
CREATE TABLE payments (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id BIGINT NOT NULL REFERENCES bookings(id),
    operation_type TEXT NOT NULL CHECK (operation_type IN ('payment', 'refund')),
    status TEXT NOT NULL CHECK (status IN ('success', 'failed')),
    amount NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    operation_key TEXT NOT NULL UNIQUE CHECK (btrim(operation_key) <> '')
);
-- На одну бронь разрешена только одна успешная оплата и один успешный возврат
CREATE UNIQUE INDEX one_successful_operation
    ON payments(booking_id, operation_type) WHERE status = 'success';
CREATE INDEX payments_by_booking ON payments(booking_id);

-- Выданные билеты (при возврате запись остается в истории со статусом returned)
CREATE TABLE tickets (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id BIGINT NOT NULL UNIQUE,
    event_seat_id BIGINT NOT NULL,
    ticket_number TEXT NOT NULL UNIQUE CHECK (btrim(ticket_number) <> ''),
    status TEXT NOT NULL DEFAULT 'valid' CHECK (status IN ('valid', 'returned')),
    issued_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    returned_at TIMESTAMPTZ,
    FOREIGN KEY (booking_id, event_seat_id)
        REFERENCES bookings(id, event_seat_id),
    CHECK (
        (status = 'valid' AND returned_at IS NULL)
        OR (status = 'returned' AND returned_at IS NOT NULL
            AND returned_at >= issued_at)
    )
);
-- На одно место может быть только один действующий билет
CREATE UNIQUE INDEX one_valid_ticket_per_seat
    ON tickets(event_seat_id) WHERE status = 'valid';
CREATE INDEX event_seats_by_status ON event_seats(event_id, status);
CREATE INDEX events_by_start ON events(starts_at);

COMMIT;