-- Этап 1. Создание и заполнение БД
-- =====================================================
-- Создание схемы для сырых данных
-- =====================================================
CREATE SCHEMA IF NOT EXISTS raw_data;

-- Таблица для импорта CSV-файла. Все поля текстовые или общие типы,
-- чтобы избежать ошибок при загрузке. Очистка и приведение типов будет
-- выполнена на этапе вставки в нормализованные таблицы.
-- Пропуски 'null' в CSV будут автоматически преобразованы в SQL NULL
-- благодаря опции NULL 'null' в команде COPY.
CREATE TABLE IF NOT EXISTS raw_data.sales(
  id INTEGER,
  auto VARCHAR,
  gasoline_consumption NUMERIC(3,1),
  price NUMERIC(15,5),
  date VARCHAR,
  person_name VARCHAR,
  phone VARCHAR,
  discount INTEGER,
  brand_origin VARCHAR
);

-- Импорт данных из CSV.
-- NULL 'null' автоматически преобразует строковые значения 'null' в SQL NULL.
COPY raw_data.sales FROM 'C:\Temp\cars.csv' WITH CSV HEADER NULL 'null';

-- =====================================================
-- Создание нормализованной схемы car_shop (3НФ)
-- =====================================================
CREATE SCHEMA IF NOT EXISTS car_shop;

-- Таблица стран (справочник)
-- country_id - суррогатный автоинкрементный первичный ключ
-- country_name - уникальное название страны
-- Вынесено в отдельную таблицу, чтобы избежать дублей ("Germany", "Германия")
-- и защитить от аномалий вставки/обновления
CREATE TABLE IF NOT EXISTS car_shop.country (
  country_id SERIAL PRIMARY KEY,
  country_name VARCHAR UNIQUE
);

-- Таблица брендов (справочник)
-- brand_id - суррогатный автоинкрементный первичный ключ
-- brand_name - уникальное название бренда
-- brand_origin - внешний ключ к стране (один бренд → одна страна)
-- Использование внешнего ключа гарантирует ссылочную целостность
CREATE TABLE IF NOT EXISTS car_shop.brand (
  brand_id SERIAL PRIMARY KEY,
  brand_name VARCHAR NOT NULL UNIQUE,
  brand_origin VARCHAR REFERENCES car_shop.country(country_name)
);

-- Таблица моделей (справочник)
-- model_id - суррогатный первичный ключ
-- brand_name - внешний ключ к бренду (ссылка по имени, т.к. brand_name уникален)
-- model_name - название модели
-- gasoline_consumption - расход топлива (характеристика модели)
-- UNIQUE (brand_name, model_name, gasoline_consumption) - расширенная уникальность
-- позволяет хранить разные модификации одной модели (разный расход топлива)
CREATE TABLE IF NOT EXISTS car_shop.model (
  model_id SERIAL PRIMARY KEY,
  brand_name VARCHAR NOT NULL REFERENCES car_shop.brand (brand_name),
  model_name VARCHAR NOT NULL,
  gasoline_consumption NUMERIC(3, 1),
  UNIQUE (brand_name, model_name, gasoline_consumption)    -- Составная уникальность: одна модель не может повторяться внутри бренда
);

-- Таблица цветов (справочник)
-- color_id - суррогатный первичный ключ
-- color_name - уникальное название цвета
-- Вынесено в отдельную таблицу, чтобы исключить повторение строк
CREATE TABLE IF NOT EXISTS car_shop.color (
  color_id SERIAL PRIMARY KEY,
  color_name VARCHAR UNIQUE NOT NULL
);

-- Таблица покупателей (справочник)
-- customer_id - суррогатный первичный ключ
-- customer_name - имя покупателя
-- phone - уникальный телефон (один покупатель = один номер)
CREATE TABLE IF NOT EXISTS car_shop.customer (
  customer_id SERIAL PRIMARY KEY,
  customer_name VARCHAR NOT NULL,
  phone VARCHAR NOT NULL UNIQUE
);

-- Таблица покупок (факты продаж)
-- purchase_id - суррогатный первичный ключ
-- model_id - внешний ключ к модели (какая модель продана)
-- color_id - внешний ключ к цвету (какого цвета)
-- customer_id - внешний ключ к покупателю (кто купил)
-- purchase_price - цена со скидкой (дробная, 2 знака после запятой)
-- discount - размер скидки в процентах
-- purchase_date - дата продажи
CREATE TABLE IF NOT EXISTS car_shop.purchase (
  purchase_id SERIAL PRIMARY KEY,
  model_id INTEGER NOT NULL REFERENCES car_shop.model (model_id),
  color_id INTEGER NOT NULL REFERENCES car_shop.color (color_id),
  customer_id INTEGER NOT NULL REFERENCES car_shop.customer (customer_id),
  purchase_price NUMERIC(9, 2),   -- Цена ПОСЛЕ скидки
  discount INTEGER,                -- Скидка в процентах
  purchase_date DATE NOT NULL
);

-- =====================================================
-- Заполнение нормализованных таблиц из сырых данных
-- =====================================================

-- Заполнение country: уникальные страны из поля brand_origin
INSERT INTO car_shop.country (country_name)
SELECT DISTINCT brand_origin FROM raw_data.sales;

-- Заполнение brand: уникальные бренды из первого слова поля auto
-- SPLIT_PART(s.auto, ' ', 1) - извлекает первое слово (название бренда)
-- LEFT JOIN с country для получения country_name (если страна не найдена - NULL)
INSERT INTO car_shop.brand (brand_name, brand_origin)
SELECT DISTINCT SPLIT_PART(s.auto, ' ', 1), c.country_name
FROM raw_data.sales s
LEFT JOIN car_shop.country c ON c.country_name = s.brand_origin;

-- Заполнение model: уникальные комбинации (бренд, модель, расход топлива)
-- Извлечение названия модели:
--   - Если встречается слово 'Model' → берем 2 и 3 слово (например "X5 M50d")
--   - Иначе берем только второе слово (например "X5")
-- TRIM удаляет лишние пробелы и запятые
-- Расход топлива берется напрямую
INSERT INTO car_shop.model (brand_name, model_name, gasoline_consumption)
SELECT DISTINCT b.brand_name,
TRIM(BOTH ' ,' FROM CASE WHEN s.auto LIKE '%Model%' 
  THEN CONCAT(SPLIT_PART(s.auto, ' ', 2), ' ', SPLIT_PART(s.auto, ' ', 3)) 
  ELSE SPLIT_PART(s.auto, ' ', 2) END),
s.gasoline_consumption
FROM raw_data.sales s
JOIN car_shop.brand b ON b.brand_name = SPLIT_PART(s.auto, ' ', 1);

-- Заполнение color: уникальные цвета
-- SPLIT_PART(s.auto, ',', 2) - извлекает значение после запятой (название цвета)
INSERT INTO car_shop.color(color_name)
SELECT DISTINCT SPLIT_PART(s.auto, ',', 2)
FROM raw_data.sales s;

-- Заполнение customer: уникальные пары (имя, телефон)
-- Предполагается, что один и тот же покупатель с одинаковым именем и телефоном
-- не дублируется.
INSERT INTO car_shop.customer(customer_name, phone)
SELECT DISTINCT c.person_name, c.phone
FROM raw_data.sales c;

-- Заполнение purchase: создание фактов продаж
-- model_id: сложный JOIN для извлечения model_name из auto
-- color_id: прямой поиск по SPLIT_PART(s.auto, ',', 2)
-- customer_id: поиск по имени покупателя
-- price: приведение к NUMERIC(9,2) с округлением/отбрасыванием лишних знаков
-- date: преобразование из VARCHAR в DATE по формату YYYY-MM-DD
INSERT INTO car_shop.purchase(model_id, color_id, customer_id, purchase_price, discount, purchase_date)
SELECT m.model_id, c.color_id, cu.customer_id, CAST(s.price AS NUMERIC(9, 2)), s.discount, TO_DATE(s.date, 'YYYY-MM-DD')
FROM raw_data.sales s
JOIN car_shop.model m ON m.model_name = trim(substring(split_part(auto, ',', 1), position(' ' IN split_part(auto, ',', 1)) + 1))
JOIN car_shop.brand b ON b.brand_name = m.brand_name
JOIN car_shop.color c ON c.color_name = SPLIT_PART(s.auto, ',', 2)
JOIN car_shop.customer cu ON cu.customer_name = s.person_name;


-- =====================================================
-- Этап 2. Создание выборок (аналитические запросы)
-- =====================================================

---- Задание 1. Напишите запрос, который выведет процент моделей машин, у которых нет параметра `gasoline_consumption`.
---- Используется агрегация с CASE: COUNT с условием считает только NULL-значения,
---- затем умножается на 100.0 и делится на общее количество. Целочисленное деление
---- дает целый результат.
SELECT
ROUND(COUNT(CASE WHEN m.gasoline_consumption IS NULL THEN 1 END) * 100.0 / COUNT(*), 2) AS nulls_percentage_gasoline_consumption
FROM car_shop.model m;

---- Задание 2. Напишите запрос, который покажет название бренда и среднюю цену его автомобилей в разбивке по всем годам с учётом скидки.
---- Цена покупки (purchase_price) уже со скидкой, поэтому дополнительно применять
---- скидку не нужно. ROUND до 2 знаков для читаемости.
---- EXTRACT(YEAR FROM p.purchase_date) - извлечение года из даты.
---- GROUP BY brand_name, year - группировка по бренду и году.
SELECT
m.brand_name, 
EXTRACT(YEAR FROM p.purchase_date) AS year, 
ROUND(AVG(p.purchase_price), 2) AS price_avg
FROM car_shop.purchase p
JOIN car_shop.model m USING (model_id)
GROUP BY m.brand_name, year 
ORDER BY m.brand_name, year ASC;

---- Задание 3. Посчитайте среднюю цену всех автомобилей с разбивкой по месяцам в 2022 году с учётом скидки.
---- WHERE EXTRACT(YEAR FROM purchase_date) = 2022 - фильтр только за 2022 год.
---- EXTRACT(MONTH) - извлечение номера месяца (1-12).
---- Цена уже со скидкой, дополнительных вычислений не требуется.
SELECT
EXTRACT(MONTH FROM p.purchase_date) AS month,
EXTRACT(YEAR FROM p.purchase_date) AS year,
ROUND(AVG(p.purchase_price), 2) AS price_avg
FROM car_shop.purchase p
WHERE EXTRACT(YEAR FROM p.purchase_date) = 2022
GROUP BY month, year
ORDER BY year, month ASC;

---- Задание 4. Напишите запрос, который выведет список купленных машин у каждого пользователя.
---- STRING_AGG объединяет названия машин в одну строку через запятую.
---- Конкатенация: brand_name || ' ' || model_name создает полное название.
---- GROUP BY customer_name - группировка по покупателю.
SELECT c.customer_name, STRING_AGG(m.brand_name || ' ' || m.model_name, ', ') AS cars
FROM car_shop.customer c
JOIN car_shop.purchase p USING (customer_id)
JOIN car_shop.model m USING (model_id)
GROUP BY c.customer_name;

---- Задание 5. Напишите запрос, который вернёт самую большую и самую маленькую цену продажи автомобиля с разбивкой по стране без учёта скидки.
---- По условию "без учёта скидки", поэтому восстанавливаем исходную цену:
---- purchase_price - цена со скидкой, discount - процент скидки.
---- Формула восстановления: price_without_discount = purchase_price / ((100.0 - discount) / 100.0)
---- ROUND применяется дважды: сначала к восстановленной цене, затем для MAX/MIN.
---- Если discount = 0 или NULL, формула корректно вернет purchase_price.
SELECT 
b.brand_origin,
MAX(ROUND(p.purchase_price / ((100.0 - p.discount) / 100.0), 2)) AS price_max,
MIN(ROUND(p.purchase_price / ((100.0 - p.discount) / 100.0), 2)) AS price_min
FROM car_shop.brand b
JOIN car_shop.model m USING (brand_name)
JOIN car_shop.purchase p USING (model_id)
GROUP BY b.brand_origin;

---- Задание 6. Напишите запрос, который покажет количество всех пользователей из США.
---- Определение по телефонному коду: +1 - код США.
---- LIKE '+1%' - ищет номера, начинающиеся с +1 (учитывает возможный код страны).
---- Простой подсчет строк без группировки.
SELECT COUNT(*) AS persons_from_usa_count
FROM car_shop.customer c 
WHERE c.phone LIKE '+1%';
