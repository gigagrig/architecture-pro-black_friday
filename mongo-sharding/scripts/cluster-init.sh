#!/bin/bash
set -euo pipefail

wait_for_mongo() {
  local service="$1"
  local port="$2"

  until docker compose exec -T "${service}" mongosh --port "${port}" --quiet --eval 'db.adminCommand({ping: 1}).ok' >/dev/null 2>&1; do
    sleep 2
  done
}

wait_for_mongo configsvr1 27017
wait_for_mongo shard1 27018
wait_for_mongo shard2 27018

docker compose exec -T configsvr1 mongosh --port 27017 --quiet <<'EOF'
try {
  rs.initiate({
    _id: "configReplSet",
    configsvr: true,
    members: [
      {_id: 0, host: "configsvr1:27017"}
    ]
  })
} catch (error) {
  if (!String(error).includes("already initialized")) {
    throw error
  }
}
EOF

docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
try {
  rs.initiate({
    _id: "shard1ReplSet",
    members: [
      {_id: 0, host: "shard1:27018"}
    ]
  })
} catch (error) {
  if (!String(error).includes("already initialized")) {
    throw error
  }
}
EOF

docker compose exec -T shard2 mongosh --port 27018 --quiet <<'EOF'
try {
  rs.initiate({
    _id: "shard2ReplSet",
    members: [
      {_id: 0, host: "shard2:27018"}
    ]
  })
} catch (error) {
  if (!String(error).includes("already initialized")) {
    throw error
  }
}
EOF

sleep 10
wait_for_mongo mongos 27017

docker compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
function addShardIfMissing(name, uri) {
  const shards = db.adminCommand({listShards: 1}).shards.map((shard) => shard._id)
  if (!shards.includes(name)) {
    sh.addShard(uri)
  }
}

addShardIfMissing("shard1ReplSet", "shard1ReplSet/shard1:27018")
addShardIfMissing("shard2ReplSet", "shard2ReplSet/shard2:27018")

sh.enableSharding("somedb")

use somedb
db.helloDoc.createIndex({age: "hashed"})

const config = db.getSiblingDB("config")
const isSharded = config.collections.findOne({_id: "somedb.helloDoc"}) !== null
if (!isSharded) {
  db.getSiblingDB("admin").runCommand({
    shardCollection: "somedb.helloDoc",
    key: {age: "hashed"},
    numInitialChunks: 4
  })
}
EOF
