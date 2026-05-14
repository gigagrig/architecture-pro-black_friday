# Отчет о проделанной работе

Выполнены задания 1, 2, 3, 4, 5, 6, 6.1, 7, 8, 9 и 10 из описания проектной работы 4.

## Задание 1. Планирование

- Обновлен файл `task1.drawio`.
- В итоговую схему добавлены:
  - несколько инстансов `pymongo-api`;
  - API Gateway / Load Balancer;
  - Consul для Service Discovery;
  - Redis для кеширования;
  - `mongos`;
  - replica set config server из трех узлов;
  - два shard replica set, по три узла в каждом;
  - CDN в нескольких регионах;
  - origin для статического контента;
  - сетевые взаимодействия между компонентами.

## Задание 2. Шардирование

- Создана директория `mongo-sharding`.
- В `mongo-sharding/compose.yaml` задано имя проекта `mongo-sharding`.
- Настроен MongoDB-кластер с:
  - `configsvr1`;
  - двумя шардами `shard1` и `shard2`;
  - `mongos`;
  - приложением `pymongo_api`.
- Добавлен `mongo-sharding/README.md` с ручными командами и быстрым сценарием инициализации.
- Добавлен скрипт `mongo-sharding/scripts/cluster-init.sh` для настройки config server, шардов и шардирования коллекции.
- Обновлен `mongo-sharding/scripts/mongo-init.sh` для загрузки 1000 документов в `somedb.helloDoc` через `mongos`.

## Задание 3. Репликация

- Создана директория `mongo-sharding-repl`.
- В `mongo-sharding-repl/compose.yaml` задано имя проекта `mongo-sharding-repl`.
- Настроены:
  - config replica set из трех узлов `configsvr1`, `configsvr2`, `configsvr3`;
  - `shard1ReplSet` из `shard1-1`, `shard1-2`, `shard1-3`;
  - `shard2ReplSet` из `shard2-1`, `shard2-2`, `shard2-3`;
  - `mongos`;
  - приложение `pymongo_api`.
- Добавлен `mongo-sharding-repl/README.md` с командами настройки репликации и шардирования.
- Добавлен `mongo-sharding-repl/scripts/cluster-init.sh` для автоматической инициализации кластера.

## Задание 4. Кеширование

- Создана директория `sharding-repl-cache`.
- В `sharding-repl-cache/compose.yaml` задано имя проекта `sharding-repl-cache`.
- В финальный стенд добавлен Redis-сервис `redis`.
- Для приложения добавлена переменная окружения `REDIS_URL=redis://redis:6379`.
- В `sharding-repl-cache/README.md` описана проверка кеширования эндпоинта `/helloDoc/users`.
- Финальный стенд содержит MongoDB sharding, replica sets и Redis-кеш.

## Задания 5 и 6. Service Discovery, API Gateway и CDN

- В `task1.drawio` отражено горизонтальное масштабирование приложения:
  - несколько реплик `pymongo-api`;
  - API Gateway / Load Balancer;
  - Consul для регистрации сервисов и health checks.
- На схему добавлен CDN:
  - CDN-регионы RU, EU и US;
  - пользователи из разных регионов;
  - origin / object storage, из которого CDN получает статический контент при cache miss.

## Задание 6.1. Инструкция для ревьюера

- Обновлен корневой `README.md`.
- В README описано, что для проверки заданий 2, 3 и 4 используется директория `sharding-repl-cache`.
- Добавлены команды запуска финального стенда:

```shell
cd sharding-repl-cache
docker compose up -d
chmod +x scripts/cluster-init.sh scripts/mongo-init.sh
./scripts/cluster-init.sh
./scripts/mongo-init.sh
```

- Описаны команды проверки MongoDB:

```shell
curl http://localhost:8080/
curl http://localhost:8080/helloDoc/count
```

- Описана проверка Redis-кеша:

```shell
curl -w '\ntime_total=%{time_total}\n' -o /dev/null -s http://localhost:8080/helloDoc/users
curl -w '\ntime_total=%{time_total}\n' -o /dev/null -s http://localhost:8080/helloDoc/users
```

## Изменения в приложении

- В копиях `api_app/app.py` добавлен диагностический вывод для `/`:
  - распределение документов коллекции по шардам;
  - количество реплик в каждом шарде;
  - признак включенного кеша.
- В compose-файлах сервис `pymongo_api` переведен на образ `kazhem/pymongo_api:1.0.0`; локальный `api_app/app.py` монтируется read-only для сохранения расширенного диагностического вывода.

## Выполненные проверки

- Проверен синтаксис Python-кода:

```shell
python3 -m py_compile mongo-sharding/api_app/app.py mongo-sharding-repl/api_app/app.py sharding-repl-cache/api_app/app.py
```

- Проверен синтаксис shell-скриптов:

```shell
bash -n mongo-sharding/scripts/mongo-init.sh mongo-sharding-repl/scripts/mongo-init.sh sharding-repl-cache/scripts/mongo-init.sh sharding-repl-cache/scripts/cluster-init.sh
```

- Проверена валидность compose-конфигураций:

```shell
docker compose config
```

для директорий `mongo-sharding`, `mongo-sharding-repl` и `sharding-repl-cache`.

- Проверена XML-валидность `task1.drawio`.

## Ограничение первичной проверки запуска

Фактический запуск финального стенда командой `docker compose up -d` был начат, но не завершился из-за внешней ошибки registry `dh-mirror.gitverse.ru` при скачивании образа MongoDB:

- сначала `i/o timeout`;
- затем `502 Bad Gateway`.

Compose-конфигурации и скрипты при этом прошли синтаксические проверки.

## Повторная проверка

При повторной проверке образ MongoDB в compose-файлах был заменен с `dh-mirror.gitverse.ru/mongo:latest` на закрепленный `mongo:7.0`, чтобы убрать зависимость от нестабильно отвечающего mirror.

После замены образа финальный стенд `sharding-repl-cache` был успешно проверен:

- `docker compose up -d --quiet-pull` завершился успешно;
- `./scripts/cluster-init.sh` успешно инициализировал:
  - config replica set;
  - `shard1ReplSet`;
  - `shard2ReplSet`;
  - подключение шардов к `mongos`;
  - sharding для `somedb.helloDoc` по hashed-ключу `age`;
- `./scripts/mongo-init.sh` загрузил 1000 документов;
- `curl http://127.0.0.1:8080/` вернул:
  - `mongo_topology_type: "Sharded"`;
  - `documents_count: 1000`;
  - два шарда `shard1ReplSet` и `shard2ReplSet`;
  - распределение документов по шардам: 521 и 479;
  - `replicas_count: 3` для каждого шарда;
  - `cache_enabled: true`;
- `curl http://127.0.0.1:8080/helloDoc/count` вернул `items_count: 1000`;
- проверка Redis-кеша для `/helloDoc/users`:
  - первый запрос: `time_total=1.022005`;
  - повторный запрос: `time_total=0.004841`.

## Задания 7-10. Архитектурный документ

- Добавлен файл `architecture_tasks_7_10.md`.
- В документе описаны схемы коллекций `products`, `orders` и `carts`.
- Для коллекций выбраны shard key и стратегии шардирования:
  - `products`: бакетизация популярных категорий через `category_bucket`;
  - `orders`: hashed sharding по `user_id`;
  - `carts`: hashed sharding по синтетическому `owner_key`.
- Добавлены примеры команд MongoDB для индексов, `shardCollection`, профилирования, balancer, `reshardCollection` и чтения с реплик.
- Описаны метрики выявления горячих шардов и меры устранения дисбаланса.
- Добавлена таблица операций чтения с указанием primary/secondary и допустимой задержки репликации.
- Описана концепция миграции части данных на Cassandra:
  - выбранные сущности;
  - partition key и clustering key;
  - примеры `CREATE TABLE`;
  - стратегии Hinted Handoff, Read Repair и Anti-Entropy Repair.
