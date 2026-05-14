# sharding-repl-cache

Финальный стенд для заданий 2, 3 и 4: `pymongo-api`, Redis, `mongos`, replica set для config server и два шарда MongoDB. Каждый шард состоит из трех реплик. База данных называется `somedb`, коллекция - `helloDoc`.
Приложение запускается из образа `kazhem/pymongo_api:1.0.0`; локальный `api_app/app.py` монтируется в контейнер для диагностического вывода по шардам, репликам и кешу.

## Запуск

```shell
docker compose up -d
```

Быстрый способ выполнить всю инициализацию кластера:

```shell
chmod +x scripts/cluster-init.sh scripts/mongo-init.sh
./scripts/cluster-init.sh
./scripts/mongo-init.sh
```

Ниже приведены те же команды по шагам.

## Инициализация config replica set

```shell
docker compose exec -T configsvr1 mongosh --port 27017 --quiet <<'EOF'
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    {_id: 0, host: "configsvr1:27017"},
    {_id: 1, host: "configsvr2:27017"},
    {_id: 2, host: "configsvr3:27017"}
  ]
})
EOF
```

## Инициализация shard replica sets

```shell
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    {_id: 0, host: "shard1-1:27018"},
    {_id: 1, host: "shard1-2:27018"},
    {_id: 2, host: "shard1-3:27018"}
  ]
})
EOF

docker compose exec -T shard2-1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    {_id: 0, host: "shard2-1:27018"},
    {_id: 1, host: "shard2-2:27018"},
    {_id: 2, host: "shard2-3:27018"}
  ]
})
EOF
```

## Подключение шардов к `mongos`

```shell
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
sh.addShard("shard1ReplSet/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2ReplSet/shard2-1:27018,shard2-2:27018,shard2-3:27018")

sh.enableSharding("somedb")

use somedb
db.helloDoc.createIndex({age: "hashed"})

use admin
db.runCommand({
  shardCollection: "somedb.helloDoc",
  key: {age: "hashed"},
  numInitialChunks: 4
})
EOF
```

## Загрузка тестовых данных

```shell
chmod +x scripts/mongo-init.sh
./scripts/mongo-init.sh
```

## Проверка MongoDB

```shell
curl http://localhost:8080/
curl http://localhost:8080/helloDoc/count
```

В ответе `/` отображаются:

- тип топологии `Sharded`;
- общее количество документов в `somedb.helloDoc`;
- распределение `helloDoc` по шардам;
- количество реплик в каждом шарде;
- признак `cache_enabled: true`.

## Проверка Redis-кеша

Первый запрос к эндпоинту `/helloDoc/users` намеренно выполняется медленнее, потому что приложение читает данные из MongoDB. Повторный запрос должен вернуться из Redis-кеша быстрее 100 мс.

```shell
curl -w '\ntime_total=%{time_total}\n' -o /dev/null -s http://localhost:8080/helloDoc/users
curl -w '\ntime_total=%{time_total}\n' -o /dev/null -s http://localhost:8080/helloDoc/users
```
