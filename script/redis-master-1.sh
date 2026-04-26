#!/bin/bash

# Demarrage du premier serveur redis avec les configuration specifiees dans le fichier
redis-server /etc/redis.conf &

# Attendre un moment, pour permettre au serveur de demarrer
sleep 5

# Creation du cluster redis
redis-cli --cluster create redis-master-1:7001 redis-master-2:7002 redredis-cli --cluster create redis-master-1:7001 redis-master-2:7002 redis-master-3:7003 redis-slave-1:7004 redis-slave-2:7005 redis-slave-3:7006 redis-slave-4:7007 redis-slave-5:7008 redis-slave-6:7009 --cluster-replicas 2 --cluster-yes
is-master-3:7003 redis-slave-1:7004 redis-slave-2:7005 redis-slave-3:7006 redis-slave-4:7007 redis-slave-5:7008 redis-slave-6:7009 --cluster-replicas 2 --cluster-yes

# Log
echo "Cluster redis deploye avec succes"

# Garder le script en execution en background
touch /dev/null
tail -f /dev/null