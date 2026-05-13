# mongo-sharding

Стенд поднимает `pymongo-api`, `mongos`, один config server и два шарда MongoDB. База данных называется `somedb`, коллекция - `helloDoc`.

## Запуск

```shell
docker compose up -d --build
```

Быстрый способ выполнить всю инициализацию кластера:

```shell
chmod +x scripts/cluster-init.sh scripts/mongo-init.sh
./scripts/cluster-init.sh
./scripts/mongo-init.sh
```

Ниже приведены те же команды по шагам.

## Инициализация config server

```shell
docker compose exec -T configsvr1 mongosh --port 27017 --quiet <<'EOF'
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    {_id: 0, host: "configsvr1:27017"}
  ]
})
EOF
```

## Инициализация шардов

```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    {_id: 0, host: "shard1:27018"}
  ]
})
EOF

docker compose exec -T shard2 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    {_id: 0, host: "shard2:27018"}
  ]
})
EOF
```

## Подключение шардов к `mongos`

```shell
docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
sh.addShard("shard1ReplSet/shard1:27018")
sh.addShard("shard2ReplSet/shard2:27018")

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

## Проверка

```shell
curl http://localhost:8080/
curl http://localhost:8080/helloDoc/count
```

В ответе `/` отображаются общее количество документов, распределение коллекции по шардам и количество реплик в каждом шарде.
