# Архитектурный документ по заданиям 7-10

Документ описывает проектирование коллекций MongoDB для интернет-магазина "Мобильный мир", подход к устранению горячих шардов, правила чтения с реплик и концепцию миграции части данных на Cassandra.

## 1. MongoDB: схемы коллекций и шардирование

### 1.1. Общие принципы

Для всех коллекций не используются монотонно растущие поля как единственный shard key. Поля `created_at`, `updated_at` и диапазонная цена удобны для сортировки и фильтрации, но как самостоятельные shard key они приводят к горячим чанкам при интенсивной записи.

Для коллекций, где основной доступ идет по владельцу сущности, используются hashed shard keys. Для каталога, где высокая доля запросов может приходиться на одну категорию, используется бакетизация категории, чтобы популярная категория не закреплялась за одним шардом.

### 1.2. Коллекция `products`

Документ товара:

```javascript
{
  _id: ObjectId("..."),
  product_id: "prd_100500",
  name: "Smartphone X",
  category: "electronics",
  category_bucket: "electronics#07",
  price: NumberDecimal("79990.00"),
  stock_by_geo: [
    { geo_zone: "msk", available: 50, reserved: 3 },
    { geo_zone: "ekb", available: 20, reserved: 1 },
    { geo_zone: "kgd", available: 30, reserved: 0 }
  ],
  attributes: {
    color: "black",
    size: "128GB"
  },
  created_at: ISODate("2026-05-01T10:00:00Z"),
  updated_at: ISODate("2026-05-14T10:00:00Z")
}
```

Кандидаты для shard key:

| Кандидат | Плюсы | Минусы |
| --- | --- | --- |
| `{ _id: "hashed" }` или `{ product_id: "hashed" }` | Равномерно распределяет товары, хорошо для страницы товара и обновления по `product_id` | Поиск по категории и цене будет scatter-gather |
| `{ category: 1, price: 1 }` | Хорошо маршрутизирует поиск в категории | Популярная категория "Электроника" создает горячий шард |
| `{ category_bucket: 1, price: 1, product_id: 1 }` | Делит популярную категорию на несколько диапазонов, сохраняет эффективный поиск по категории и цене | Запрос по категории должен обращаться к нескольким bucket-значениям |

Выбранная стратегия: range-based sharding по синтетическому ключу `{ category_bucket: 1, price: 1, product_id: 1 }`.

`category_bucket` формируется приложением как `category + "#" + bucket`, где `bucket = hash(product_id) % 32`. Для поиска товаров в категории приложение строит список bucket-значений, например `electronics#00` ... `electronics#31`, и выполняет запрос с `$in`. Так популярная категория распределяется по нескольким чанкам и шардам, а фильтр по цене остается частью shard key.

Команды MongoDB:

```javascript
use shop

db.products.createIndex(
  { category_bucket: 1, price: 1, product_id: 1 },
  { name: "shard_category_bucket_price_product" }
)

db.products.createIndex(
  { product_id: 1 },
  { name: "product_id_lookup" }
)

db.adminCommand({
  shardCollection: "shop.products",
  key: { category_bucket: 1, price: 1, product_id: 1 }
})
```

Пример запроса каталога:

```javascript
db.products.find({
  category_bucket: {
    $in: [
      "electronics#00", "electronics#01", "electronics#02", "electronics#03",
      "electronics#04", "electronics#05", "electronics#06", "electronics#07"
    ]
  },
  price: { $gte: NumberDecimal("10000.00"), $lte: NumberDecimal("100000.00") }
}).sort({ price: 1 }).limit(50)
```

Для точечного обновления остатков сервис заказа должен передавать `category_bucket` вместе с `product_id`. Это делает update таргетированным:

```javascript
db.products.updateOne(
  {
    category_bucket: "electronics#07",
    product_id: "prd_100500",
    "stock_by_geo.geo_zone": "msk",
    "stock_by_geo.available": { $gte: 1 }
  },
  {
    $inc: {
      "stock_by_geo.$.available": -1,
      "stock_by_geo.$.reserved": 1
    },
    $set: { updated_at: new Date() }
  }
)
```

### 1.3. Коллекция `orders`

Документ заказа:

```javascript
{
  _id: ObjectId("..."),
  order_id: "ord_900001",
  user_id: "usr_12345",
  created_at: ISODate("2026-05-14T09:15:00Z"),
  items: [
    {
      product_id: "prd_100500",
      name: "Smartphone X",
      category: "electronics",
      quantity: 1,
      price: NumberDecimal("79990.00")
    }
  ],
  status: "paid",
  total_amount: NumberDecimal("79990.00"),
  geo_zone: "msk"
}
```

Кандидаты для shard key:

| Кандидат | Плюсы | Минусы |
| --- | --- | --- |
| `{ _id: "hashed" }` или `{ order_id: "hashed" }` | Равномерная запись и быстрый поиск заказа по id | История заказов пользователя будет scatter-gather |
| `{ user_id: "hashed" }` | Равномерная запись, таргетированная история заказов пользователя | Статус заказа нужно читать с `user_id` или через отдельный lookup |
| `{ geo_zone: 1, created_at: 1 }` | Удобно для региональной аналитики | Риск горячего региона и горячего последнего диапазона |

Выбранная стратегия: hashed sharding по `{ user_id: "hashed" }`.

Главный пользовательский сценарий - история заказов конкретного пользователя. Создание заказа также равномерно распределяется, если поток заказов идет от большого количества пользователей. API статуса заказа должен принимать `user_id` из авторизационного контекста и `order_id`; тогда запрос будет таргетирован на один шард.

Команды MongoDB:

```javascript
use shop

db.orders.createIndex(
  { user_id: "hashed" },
  { name: "shard_user_hashed" }
)

db.orders.createIndex(
  { user_id: 1, created_at: -1, order_id: 1 },
  { name: "user_order_history" }
)

db.orders.createIndex(
  { user_id: 1, order_id: 1 },
  { name: "user_order_status" }
)

db.adminCommand({
  shardCollection: "shop.orders",
  key: { user_id: "hashed" }
})
```

Примеры операций:

```javascript
db.orders.find({ user_id: "usr_12345" })
  .sort({ created_at: -1 })
  .limit(20)

db.orders.findOne(
  { user_id: "usr_12345", order_id: "ord_900001" },
  { status: 1, total_amount: 1, created_at: 1 }
)
```

### 1.4. Коллекция `carts`

Для корзин вводится синтетическое поле `owner_key`, чтобы одинаково маршрутизировать гостевые и пользовательские корзины:

- для пользователя: `owner_key = "u:" + user_id`;
- для гостя: `owner_key = "s:" + session_id`.

Документ корзины:

```javascript
{
  _id: ObjectId("..."),
  cart_id: "crt_777",
  owner_key: "u:usr_12345",
  user_id: "usr_12345",
  session_id: null,
  items: [
    { product_id: "prd_100500", quantity: 1 },
    { product_id: "prd_200700", quantity: 2 }
  ],
  status: "active",
  created_at: ISODate("2026-05-14T08:00:00Z"),
  updated_at: ISODate("2026-05-14T09:00:00Z"),
  expires_at: ISODate("2026-06-13T08:00:00Z")
}
```

Кандидаты для shard key:

| Кандидат | Плюсы | Минусы |
| --- | --- | --- |
| `{ _id: "hashed" }` | Равномерно распределяет корзины | Получение активной корзины по `user_id` или `session_id` будет scatter-gather |
| `{ user_id: "hashed" }` | Хорошо для авторизованных пользователей | Не покрывает гостевые корзины |
| `{ owner_key: "hashed" }` | Единый ключ для гостя и пользователя, таргетирует основные операции | Слияние гостевой и пользовательской корзины обращается к двум шардам |

Выбранная стратегия: hashed sharding по `{ owner_key: "hashed" }`.

Все основные операции с активной корзиной выполняются по `owner_key` и `status`, поэтому они маршрутизируются на один шард. Слияние гостевой корзины в пользовательскую затрагивает два `owner_key`, но это ожидаемый редкий сценарий по сравнению с чтением и изменением активной корзины.

Команды MongoDB:

```javascript
use shop

db.carts.createIndex(
  { owner_key: "hashed" },
  { name: "shard_owner_hashed" }
)

db.carts.createIndex(
  { owner_key: 1, status: 1, updated_at: -1 },
  { name: "active_cart_by_owner" }
)

db.carts.createIndex(
  { expires_at: 1 },
  { name: "cart_ttl", expireAfterSeconds: 0 }
)

db.adminCommand({
  shardCollection: "shop.carts",
  key: { owner_key: "hashed" }
})
```

Примеры операций:

```javascript
db.carts.findOne({
  owner_key: "s:session_abc",
  status: "active"
})

db.carts.updateOne(
  {
    owner_key: "u:usr_12345",
    status: "active",
    "items.product_id": "prd_100500"
  },
  {
    $set: {
      "items.$.quantity": 2,
      updated_at: new Date()
    }
  }
)
```

## 2. Горячие шарды: выявление и устранение

### 2.1. Метрики мониторинга

| Группа метрик | Что отслеживать | Зачем |
| --- | --- | --- |
| Распределение данных | `dataSize`, `storageSize`, `count`, количество чанков по шардам | Видеть дисбаланс хранения и слишком крупные чанки |
| Нагрузка | ops/sec по `find`, `insert`, `update`, `delete`, latency p95/p99 по шардам | Находить шард, который обслуживает непропорционально много запросов |
| Запросы по категориям | QPS и p95/p99 по `category`, число запросов к `electronics` | Быстро выявлять популярные категории, создающие горячую нагрузку |
| Балансировка | состояние balancer, количество миграций чанков, failed migrations, jumbo chunks | Понимать, справляется ли автоматический перенос чанков |
| Ресурсы узлов | CPU, disk IOPS, disk queue, network, WiredTiger cache usage, eviction rate | Отличать проблему shard key от нехватки ресурсов |
| Репликация | replication lag, oplog window, rollback events | Контролировать, не отстают ли secondary при росте записи |
| Блокировки | lock time, write conflicts, queued readers/writers | Находить contention при частых обновлениях остатков |

Примеры команд:

```javascript
sh.status()

use shop
db.products.getShardDistribution()
db.orders.getShardDistribution()
db.carts.getShardDistribution()

db.products.aggregate([
  { $collStats: { latencyStats: { histograms: true }, storageStats: {} } }
])

db.adminCommand({ balancerStatus: 1 })
db.adminCommand({ listShards: 1 })

db.adminCommand({
  analyzeShardKey: "shop.products",
  key: { category_bucket: 1, price: 1, product_id: 1 }
})
```

Пример профилирования горячих категорий:

```javascript
use shop

db.setProfilingLevel(1, { slowms: 100 })

db.system.profile.aggregate([
  { $match: { ns: "shop.products", "command.filter.category": { $exists: true } } },
  {
    $group: {
      _id: "$command.filter.category",
      count: { $sum: 1 },
      avg_ms: { $avg: "$millis" },
      max_ms: { $max: "$millis" }
    }
  },
  { $sort: { count: -1 } }
])
```

### 2.2. Меры устранения дисбаланса

Если горячий шард возник из-за shard key `{ category: 1, price: 1 }`, перенос отдельных чанков даст временный эффект: новые запросы по категории все равно будут концентрироваться на ограниченном наборе чанков. Долгосрочное решение - изменить модель shard key так, чтобы популярная категория была разделена на несколько независимых диапазонов.

Основные меры:

| Мера | Когда применять | Команды и настройки |
| --- | --- | --- |
| Включить и контролировать balancer | Базовая автоматическая миграция чанков | `sh.startBalancer()`, `sh.isBalancerRunning()` |
| Бакетизировать популярные категории | 70% запросов идет в одну категорию | `category_bucket = category + "#" + hash(product_id) % 32` |
| Выполнить `reshardCollection` | Текущий shard key уже приводит к горячим шардам | Перешардировать на `{ category_bucket: 1, price: 1, product_id: 1 }` |
| Предварительно создать чанки | Перед распродажей известны горячие категории | Создать диапазоны bucket-ключей заранее |
| Разнести чтение каталога и запись остатков | Каталог читается чаще, остатки часто обновляются | Кеш, read model, при необходимости отдельная коллекция остатков |
| Добавить шарды до пика | Ресурсы шарда упираются в CPU/IOPS | Добавить шард заранее, дождаться завершения балансировки |

Пример настройки balancer:

```javascript
sh.startBalancer()
sh.isBalancerRunning()

db.adminCommand({
  configureCollectionBalancing: "shop.products",
  chunkSize: 128
})
```

Пример перешардирования коллекции товаров:

```javascript
db.adminCommand({
  reshardCollection: "shop.products",
  key: { category_bucket: 1, price: 1, product_id: 1 }
})
```

Пример ручного переноса чанка как временной аварийной меры:

```javascript
sh.moveChunk(
  "shop.products",
  { category_bucket: "electronics#07", price: NumberDecimal("50000.00") },
  "shard2ReplSet"
)
```

## 3. Чтение с реплик и консистентность

Общее правило: операции, влияющие на покупку, оплату, списание остатков, активную корзину и текущий статус заказа, читают с primary. Secondary можно использовать для каталожных страниц, истории и аналитики, где допустима небольшая задержка репликации.

### 3.1. Таблица операций

| Коллекция | Операция чтения | Источник чтения | Допустимая задержка secondary | Обоснование |
| --- | --- | --- | --- | --- |
| `products` | Страница товара: название, описание, характеристики | Secondary допустима | До 30 секунд | Описание товара редко меняется, небольшая задержка не приводит к продаже отсутствующего товара |
| `products` | Поиск по категории и цене | Secondary допустима | До 30 секунд | Каталог может быть слегка устаревшим, зато чтение масштабируется |
| `products` | Проверка доступного остатка перед оформлением заказа | Только primary | 0 секунд | Устаревший остаток может привести к продаже недоступного товара |
| `products` | Повторная проверка остатка при списании | Только primary | 0 секунд | Должна выполняться вместе с условным update `available >= quantity` |
| `orders` | Создание заказа и чтение результата сразу после создания | Только primary | 0 секунд | Пользователь должен увидеть только что созданный заказ |
| `orders` | Текущий статус заказа на странице заказа | Primary, для неактивных заказов secondary допустима | 0 секунд для активных, до 5 секунд для завершенных | Для активного заказа устаревший статус ухудшает UX и может ломать бизнес-логику |
| `orders` | История заказов пользователя | Secondary допустима | До 5 секунд | История читается часто, небольшая задержка приемлема после подтверждения заказа |
| `orders` | Операции поддержки и аналитика по геозоне/status | Secondary | До 60 секунд | Это не влияет на оформление заказа |
| `carts` | Получение активной корзины по `session_id` или `user_id` | Только primary | 0 секунд | Корзина часто меняется, stale read может потерять добавленный товар |
| `carts` | Чтение корзины перед merge гостя в пользователя | Только primary | 0 секунд | Нужна актуальная гостевая и пользовательская корзина |
| `carts` | Отображение уже заказанной или abandoned корзины | Secondary допустима | До 30 секунд | Не участвует в оформлении текущего заказа |
| `carts` | Фоновые отчеты по abandoned carts | Secondary | До 60 секунд | Аналитика допускает задержку |

### 3.2. Примеры настроек клиента

Для чтения каталога с secondary:

```python
from pymongo import MongoClient, ReadPreference

client = MongoClient(
    MONGO_URL,
    readPreference="secondaryPreferred",
    maxStalenessSeconds=30
)

products = client.shop.get_collection(
    "products",
    read_preference=ReadPreference.SECONDARY_PREFERRED
)
```

Для критичных операций используется primary и majority:

```python
from pymongo import MongoClient, ReadConcern, WriteConcern

client = MongoClient(MONGO_URL)

orders = client.shop.get_collection(
    "orders",
    read_concern=ReadConcern("majority"),
    write_concern=WriteConcern("majority", wtimeout=5000)
)

order = orders.find_one({
    "user_id": "usr_12345",
    "order_id": "ord_900001"
})
```

Для мониторинга задержки репликации:

```javascript
rs.printSecondaryReplicationInfo()
rs.status()
```

## 4. Миграция на Cassandra

### 4.1. Какие данные переносить

Cassandra имеет смысл применять там, где важны горизонтальная масштабируемость, высокая доступность, геораспределение и предсказуемая latency при больших объемах записи и чтения.

| Данные | Критичность | Переносить в Cassandra | Причина |
| --- | --- | --- | --- |
| Заказы и история заказов | Высокая | Да, как order storage и read model | Запись append-heavy, чтение по пользователю и заказу хорошо моделируется таблицами под запрос |
| Статусы заказов | Высокая | Да, с `LOCAL_QUORUM` | Нужна высокая доступность и быстрый lookup по `order_id` |
| Товары: каталог и карточки | Средняя | Да, как read model | Чтение масштабируется, допустима eventual consistency для описаний |
| Остатки товаров | Очень высокая | Частично, осторожно | Cassandra подходит для распределенной доступности, но точное списание требует LWT или отдельного inventory-сервиса |
| Корзины | Высокая для UX, средняя для финансовой целостности | Да | Частые записи, TTL, доступ по владельцу, хорошее соответствие Cassandra |
| Пользовательские сессии | Средняя | Да | TTL и быстрый lookup по session id |
| Финансовый ledger и платежные проводки | Очень высокая | Нет как единственный источник истины | Нужны строгие транзакционные гарантии и аудит |

Итог: в Cassandra переносим `orders`, `order_status`, `order_history`, `product_catalog` read model, `carts`, `sessions` и inventory reservation/read model. Для финансовых операций и окончательного учета платежей нужен отдельный строго консистентный контур.

### 4.2. Репликация и распределение в Cassandra

Рекомендуемая стратегия репликации:

```sql
CREATE KEYSPACE mobile_world
WITH replication = {
  'class': 'NetworkTopologyStrategy',
  'dc1': 3,
  'dc2': 3
}
AND durable_writes = true;
```

Для пользовательских операций в одном регионе:

- запись: `LOCAL_QUORUM`;
- чтение критичных данных: `LOCAL_QUORUM`;
- чтение каталога и сессий при допустимой устарелости: `LOCAL_ONE` или `LOCAL_QUORUM` в зависимости от сценария.

Cassandra распределяет partition keys по token ring. При добавлении узла переносится только часть token ranges, а не полное перераспределение всех данных, как в проблемном сценарии range-based sharding.

### 4.3. Концептуальная модель Cassandra

Модель строится от запросов. Дублирование данных между таблицами допустимо, потому что Cassandra не предназначена для произвольных join-запросов.

#### Заказ по id

Запрос: получить заказ или статус по `order_id`.

```sql
CREATE TABLE mobile_world.orders_by_id (
  order_id text,
  user_id text,
  created_at timestamp,
  status text,
  total_amount decimal,
  geo_zone text,
  items_json text,
  updated_at timestamp,
  PRIMARY KEY ((order_id))
) WITH read_repair = 'BLOCKING';
```

`order_id` должен быть UUID/ULID с высокой кардинальностью, чтобы равномерно распределяться по token ring. Таблица дает быстрый lookup без горячих диапазонов.

#### История заказов пользователя

Запрос: показать историю заказов пользователя за период.

```sql
CREATE TABLE mobile_world.orders_by_user_month (
  user_id text,
  order_month text,
  created_at timestamp,
  order_id text,
  status text,
  total_amount decimal,
  geo_zone text,
  PRIMARY KEY ((user_id, order_month), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC, order_id ASC)
  AND read_repair = 'BLOCKING';
```

Partition key `(user_id, order_month)` ограничивает размер партиции. Даже у активного пользователя история делится по месяцам, поэтому одна партиция не растет бесконечно.

#### Каталог по категории и цене

Запрос: товары категории с фильтром по цене.

```sql
CREATE TABLE mobile_world.products_by_category_bucket (
  category text,
  bucket int,
  price decimal,
  product_id text,
  name text,
  attributes_json text,
  updated_at timestamp,
  PRIMARY KEY ((category, bucket), price, product_id)
) WITH CLUSTERING ORDER BY (price ASC, product_id ASC)
  AND read_repair = 'NONE';
```

`bucket = hash(product_id) % 32`. Популярная категория "electronics" распределяется по 32 партициям: `(electronics, 0)` ... `(electronics, 31)`. Запрос по категории выполняется fan-out по bucket-значениям и объединяется на уровне сервиса.

#### Карточка товара по id

```sql
CREATE TABLE mobile_world.products_by_id (
  product_id text,
  category text,
  bucket int,
  name text,
  price decimal,
  attributes_json text,
  updated_at timestamp,
  PRIMARY KEY ((product_id))
) WITH read_repair = 'NONE';
```

Точечный доступ по `product_id` равномерно распределяется по кластеру.

#### Остатки и резервирование

Для точного списания остатков Cassandra требует осторожности. Один ряд `(product_id, geo_zone)` для популярного товара станет горячей партицией. Чтобы снизить contention, остаток делится на слоты.

```sql
CREATE TABLE mobile_world.inventory_slots_by_product_geo (
  product_id text,
  geo_zone text,
  slot int,
  available int,
  reserved int,
  updated_at timestamp,
  PRIMARY KEY ((product_id, geo_zone, slot))
) WITH read_repair = 'BLOCKING';
```

Сервис выбирает слот случайно или по hash от `order_id`, читает текущие значения и выполняет условное compare-and-set списание:

```sql
UPDATE mobile_world.inventory_slots_by_product_geo
SET available = 49,
    reserved = 4,
    updated_at = toTimestamp(now())
WHERE product_id = 'prd_100500'
  AND geo_zone = 'msk'
  AND slot = 7
IF available = 50;
```

LWT повышает latency, поэтому его стоит применять только для финального резервирования. Для отображения каталога можно использовать eventually consistent read model.

#### Корзина владельца

Запрос: получить активную корзину по пользователю или сессии.

```sql
CREATE TABLE mobile_world.carts_by_owner (
  owner_key text,
  status text,
  cart_id text,
  updated_at timestamp,
  expires_at timestamp,
  PRIMARY KEY ((owner_key), status, cart_id)
) WITH default_time_to_live = 2592000
  AND read_repair = 'BLOCKING';
```

`owner_key` имеет формат `u:<user_id>` или `s:<session_id>`. Это равномерно распределяет корзины и таргетирует основной запрос.

Позиции корзины:

```sql
CREATE TABLE mobile_world.cart_items_by_cart (
  cart_id text,
  product_id text,
  quantity int,
  updated_at timestamp,
  PRIMARY KEY ((cart_id), product_id)
) WITH default_time_to_live = 2592000
  AND read_repair = 'BLOCKING';
```

Разделение корзины и позиций позволяет обновлять один товар без перезаписи большого документа.

#### Пользовательские сессии

```sql
CREATE TABLE mobile_world.sessions_by_id (
  session_id text,
  user_id text,
  created_at timestamp,
  updated_at timestamp,
  expires_at timestamp,
  PRIMARY KEY ((session_id))
) WITH default_time_to_live = 2592000
  AND read_repair = 'NONE';
```

Сессии хорошо подходят для Cassandra: доступ идет по ключу, данные имеют TTL, небольшая устарелость обычно допустима.

### 4.4. Стратегии целостности

| Стратегия | Где применять | Обоснование |
| --- | --- | --- |
| Hinted Handoff | Все write-heavy таблицы: `orders_by_id`, `orders_by_user_month`, `carts_by_owner`, `cart_items_by_cart`, `sessions_by_id`, `inventory_slots_by_product_geo` | Снижает риск потери записи при кратковременной недоступности узла и почти не влияет на latency успешного write path |
| Read Repair | `orders_by_id`, `orders_by_user_month`, `carts_by_owner`, `cart_items_by_cart`, `inventory_slots_by_product_geo` | Пользовательские чтения должны подтягивать расхождения между репликами; цена - повышенная latency чтения |
| Anti-Entropy Repair | Все таблицы по расписанию, чаще для заказов и inventory | Полная фоновая сверка нужна после долгих отказов, missed hints и сетевых разделений |

Рекомендуемые интервалы:

| Сущность | Consistency level | Repair-политика |
| --- | --- | --- |
| Заказы и статусы | `LOCAL_QUORUM` на запись и чтение | Hinted Handoff, Read Repair, Anti-Entropy Repair не реже 1 раза в сутки |
| История заказов | `LOCAL_QUORUM` на запись, `LOCAL_QUORUM` или `LOCAL_ONE` на чтение истории | Anti-Entropy Repair ежедневно, Read Repair для пользовательских чтений |
| Корзины | `LOCAL_QUORUM` на запись и чтение активной корзины | Hinted Handoff, Read Repair, repair до истечения TTL |
| Сессии | `LOCAL_QUORUM` на запись, `LOCAL_ONE` на чтение | Hinted Handoff, Anti-Entropy Repair менее критичен из-за TTL |
| Каталог товаров | `LOCAL_QUORUM` на запись, `LOCAL_ONE` или `LOCAL_QUORUM` на чтение | Read Repair можно отключить, регулярный repair по расписанию |
| Inventory slots | `LOCAL_QUORUM` и LWT для резервирования | Hinted Handoff, Read Repair, частый Anti-Entropy Repair; принимать повышенную latency ради защиты от oversell |

Примеры настроек:

```yaml
# cassandra.yaml
hinted_handoff_enabled: true
max_hint_window: 3h
num_tokens: 16
```

Примеры команд обслуживания:

```shell
nodetool status
nodetool netstats
nodetool repair mobile_world orders_by_id
nodetool repair mobile_world inventory_slots_by_product_geo
```

Компромисс: для каталога и сессий можно снижать latency чтения через `LOCAL_ONE`, потому что небольшая устарелость приемлема. Для заказов, активных корзин и резервирования остатков выбирается `LOCAL_QUORUM`, read repair и регулярный anti-entropy repair, потому что ошибка целостности напрямую влияет на деньги, выполнение заказа и пользовательский сценарий покупки.
