# Проектная работа 4

В репозитории подготовлены три стенда:

- `mongo-sharding` - MongoDB с двумя шардами;
- `mongo-sharding-repl` - шардирование и репликация, по три реплики на каждый шард;
- `sharding-repl-cache` - финальная реализация с MongoDB sharding, replica sets и Redis-кешем.

Для проверки заданий 2, 3 и 4 используйте директорию `sharding-repl-cache`.

## Запуск финального стенда

```shell
cd sharding-repl-cache
docker compose up -d --build
chmod +x scripts/cluster-init.sh scripts/mongo-init.sh
./scripts/cluster-init.sh
./scripts/mongo-init.sh
```

После этого приложение доступно на `http://localhost:8080`.

## Проверка MongoDB

```shell
curl http://localhost:8080/
curl http://localhost:8080/helloDoc/count
```

В ответе `/` должны быть видны:

- `mongo_topology_type: "Sharded"`;
- коллекция `helloDoc` в базе `somedb`;
- общее количество документов `>= 1000`;
- распределение документов по шардам;
- два шарда `shard1ReplSet` и `shard2ReplSet`;
- `replicas_count: 3` для каждого шарда;
- `cache_enabled: true`.

## Проверка Redis-кеша

Эндпоинт `/helloDoc/users` кешируется на 60 секунд. Первый запрос выполняется с искусственной задержкой, повторный должен быть быстрее 100 мс.

```shell
curl -w '\ntime_total=%{time_total}\n' -o /dev/null -s http://localhost:8080/helloDoc/users
curl -w '\ntime_total=%{time_total}\n' -o /dev/null -s http://localhost:8080/helloDoc/users
```

## Схема

Итоговая схема для заданий 1, 5 и 6 находится в файле `task1.drawio`. На ней отражены:

- несколько инстансов `pymongo-api`;
- API Gateway и Consul для Service Discovery;
- Redis;
- `mongos`, config replica set и два shard replica set;
- CDN в нескольких регионах и origin для статического контента.

## Архитектурный документ для заданий 7-10

Решение заданий 7-10 находится в файле `architecture_tasks_7_10.md`. В нем описаны схемы коллекций MongoDB, shard key, стратегия устранения горячих шардов, чтение с реплик и концепция миграции части данных на Cassandra.
