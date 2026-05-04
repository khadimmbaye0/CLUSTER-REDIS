---
marp: true
theme: uncover
paginate: true
size: 16:9
---

# **Atelier NoSQL — Redis**

## Déploiement, Sécurisation & Haute Disponibilité

### DIC2 — SEM2 — 2026

---

## **Sommaire**

1. Déploiement d'un cluster Redis
2. Gestion des utilisateurs (ACL)
3. Réplication & Distribution des données
4. Tolérance aux partitions, disponibilité, cohérence
5. Maintenance & Optimisation

---

## **1. Déploiement du cluster**

---

### **Architecture globale**

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│ Master 1    │   │ Master 2    │   │ Master 3    │
│ :7001       │   │ :7002       │   │ :7003       │
└──┬──────┬───┘   └──┬──────┬───┘   └──┬──────┬───┘
   │      │          │      │          │      │
   ▼      ▼          ▼      ▼          ▼      ▼
┌────┐ ┌────┐    ┌────┐ ┌────┐    ┌────┐ ┌────┐
│ S1 │ │ S2 │    │ S3 │ │ S4 │    │ S5 │ │ S6 │
│:7004│:7005│    │:7006│:7007│    │:7008│:7009│
└────┘ └────┘    └────┘ └────┘    └────┘ └────┘
```

**9 nœuds** — 3 masters, 6 slaves — 2 réplicas par master

---

### **Stack technique**

| Composant | Technologie | Port |
|-----------|------------|------|
| Moteur | **Redis 7.0.0** | 7001-7009 |
| Orchestration | **Docker Compose** | — |
| Monitoring | **redis-stat** | 8080 |
| GUI | **RedisInsight** | 5540 |
| Bus cluster | **Redis Cluster Bus** | 17001-17009 |

---

### **Configuration d'un nœud**

```conf
# config/redis-master-1.conf
port 7001
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 3000
appendonly yes
aclfile /etc/redis/users.acl
masterauth Admin@Cluster2026
masteruser admin
```

- `cluster-enabled yes` → mode cluster activé
- `appendonly yes` → persistance AOF
- `aclfile` → fichier ACL externe partagé
- `masterauth` + `masteruser` → auth inter-nœuds

---

### **Création du cluster**

```bash
redis-cli --cluster create \
  redis-master-1:7001 redis-master-2:7002 redis-master-3:7003 \
  redis-slave-1:7004  redis-slave-2:7005  redis-slave-3:7006 \
  redis-slave-4:7007  redis-slave-5:7008  redis-slave-6:7009 \
  --cluster-replicas 2 \
  --cluster-yes \
  --user admin -a Admin@Cluster2026
```

- `--cluster-replicas 2` → chaque master a **2 slaves**
- Authentification obligatoire pour créer le cluster

---

### **Démarrage**

```bash
# Lancer tout le cluster
docker compose -p "redis-cluster" up -d

# Vérifier l'état
docker exec -it redis-master-1 bash
redis-cli -c -p 7001
> CLUSTER INFO
> CLUSTER NODES
```

- `-c` = mode cluster (suivi des redirections MOVED/ASK)
- `CLUSTER INFO` → état global du cluster
- `CLUSTER NODES` → topologie complète

---

## **2. Gestion des utilisateurs**

---

### **Fichier ACL — `config/users.acl`**

```acl
user default  on >Default@Stat2026  ~* &* -@all +@read +INFO +PING
              +CLUSTER|INFO +CLUSTER|NODES +CLUSTER|SLOTS
              +CLIENT|LIST +SLOWLOG +CONFIG|GET +MEMORY +COMMAND

user admin    on >Admin@Cluster2026 ~* &* +@all

user appuser  on >App@Pass2026      ~app:* &* +@read +@write
              +DEL +EXPIRE +TTL -FLUSHDB -FLUSHALL -CONFIG

user readonly on >Read@Only2026     ~* &* +@read +INFO +PING
              +CLUSTER|INFO +CLUSTER|NODES +CLUSTER|SLOTS
              -FLUSHDB -FLUSHALL -CONFIG

user insight  on >Insight@Pass2026  ~* &* +@all
```

---

### **Rôles et permissions**

| Utilisateur | Mot de passe | Permissions | Usage |
|-------------|-------------|-------------|-------|
| **admin** | `Admin@Cluster2026` | `+@all` | Admin cluster |
| **default** | `Default@Stat2026` | `+@read`, commandes info | Monitoring (redis-stat) |
| **appuser** | `App@Pass2026` | `+@read +@write` sur `app:*` | Application |
| **readonly** | `Read@Only2026` | `+@read` uniquement | Lecture seule |
| **insight** | `Insight@Pass2026` | `+@all` | RedisInsight GUI |

---

### **Sécurité par isolation**

```
┌────────────────────────────────────────────┐
│  appuser → app:*   (lecture/écriture)       │
│  readonly → *      (lecture seule)          │
│  default → *       (monitoring seulement)   │
│  admin → *         (tout)                   │
└────────────────────────────────────────────┘
```

- **Préfixe de clé `app:*`** isole les données applicatives
- Commandes dangereuses bloquées pour `appuser` : `FLUSHDB`, `FLUSHALL`, `CONFIG`
- Principe du **moindre privilège**

---

### **Vérification ACL**

```bash
# Lister les utilisateurs
redis-cli -c -p 7001 --user admin -a Admin@Cluster2026
> ACL LIST

# Tester avec appuser
> AUTH appuser App@Pass2026
> SET app:key1 "valeur"    # OK
> SET autre:key1 "valeur"  # REFUSÉ — hors préfixe app:*
> FLUSHDB                   # REFUSÉ — commande bloquée
```

---

## **3. Réplication & Distribution**

---

### **Distribution : Hash Slots (16 384 slots)**

```
┌──────────────┬──────────────┬──────────────┐
│   Master 1    │   Master 2    │   Master 3    │
│  Slots 0-5460 │ Slots 5461-  │ Slots 10923-  │
│               │     10922    │     16383     │
└──────────────┴──────────────┴──────────────┘
```

- Chaque clé mappée sur 1 slot : `CRC16(key) % 16384`
- Les slots sont répartis entre les **3 masters**
- `CLUSTER KEYSLOT ma_cle` → voir le slot d'une clé

---

### **Réplication : 2 slaves par master**

```
     Master 1 (:7001)       ── Slave 1 (:7004)
                            ── Slave 2 (:7005)
                            
     Master 2 (:7002)       ── Slave 3 (:7006)
                            ── Slave 4 (:7007)
                            
     Master 3 (:7003)       ── Slave 5 (:7008)
                            ── Slave 6 (:7009)
```

- Réplication **asynchrone** par défaut
- Chaque slave peut devenir master (failover automatique)
- 2 réplicas = redondance renforcée

---

### **Démonstration : Distribution**

```bash
# Connexion en mode cluster
redis-cli -c -p 7001

> SET nom "Khadim"          # → slot 1234 → Master 1
> SET email "khadim@test"   # → slot 9876 → Master 2 (REDIRECT)
> GET nom                    # → REDIRECT vers Master 1
```

Le client suit automatiquement les redirections `MOVED`

---

### **Démonstration : Réplication**

```bash
# Vérifier le rôle d'un nœud
> ROLE
# master → "master" + liste des slaves
# slave  → "slave" + master_host + master_port

# Vérifier la réplication
> INFO replication
```

- `connected_slaves:2` sur chaque master
- `master_link_status:up` sur chaque slave
- `master_repl_offset` → décalage de réplication

---

## **4. Tolérance aux partitions, disponibilité, cohérence**

---

### **Théorème CAP — Positionnement Redis Cluster**

```
         ┌─────────────────┐
        ╱                   ╲
       │    Consistency      │
       │         ✗           │
        ╲                   ╱
         │                 │
         │    Redis        │
         │    Cluster      │
         │                 │
        ╱                   ╲
       │   Partition Tol.    │
       │         ✓           │
        ╲                   ╱
         └─────────────────┘
               Availability
                    ✓
```

**Redis Cluster = AP** (Availability + Partition Tolerance)

---

### **Failover automatique**

```
1. Master 1 tombe
       ↓
2. cluster-node-timeout (3000ms) écoulé
       ↓
3. Les slaves de Master 1 détectent la panne
       ↓
4. Élection parmi les slaves → nouveau Master 1
       ↓
5. Topologie mise à jour (gossip protocol)
       ↓
6. Cluster opérationnel (~3-5 secondes)
```

Avec **2 slaves** par master : un seul slave survivant suffit pour le failover

---

### **Démonstration : Test de partition**

```bash
# 1. Vérifier l'état initial
redis-cli -c -p 7001 CLUSTER INFO
# cluster_state:ok

# 2. Arrêter un master
docker stop redis-master-1

# 3. Observer le failover (attendre ~5s)
redis-cli -c -p 7004 CLUSTER INFO
# cluster_state:ok — un slave a pris le relais

# 4. Redémarrer l'ancien master
docker start redis-master-1
# Il revient en tant que slave du nouveau master
```

---

### **Cohérence des données**

| Mécanisme | Détail |
|-----------|--------|
| **Persistence** | AOF (`appendonly yes`) sur tous les nœuds |
| **Réplication** | Asynchrone → risque de perte minime si master crash avant propagation |
| **WAIT** | `WAIT numreplicas timeout` → synchrone optionnel |
| **READONLY** | Lecture possible sur les slaves (cohérence éventuelle) |

```bash
# Forcer N réplicas à accuser réception
> SET key value
> WAIT 1 1000   # Attendre 1 slave, timeout 1000ms
```

---

## **5. Maintenance & Optimisation**

---

### **Monitoring : redis-stat**

```
http://localhost:8080
```

- Vue temps réel de tous les nœuds (9 serveurs)
- Métriques : mémoire, connexions, ops/sec, hit ratio
- Authentifié via utilisateur `default`

---

### **Monitoring : RedisInsight**

```
http://localhost:5540
```

- Interface graphique complète
- Analyse des clés, mémoire, slowlog
- Exploration des données en temps réel
- Authentifié via utilisateur `insight`

---

### **Commandes de diagnostic**

```bash
# Mémoire utilisée par nœud
redis-cli -p 7001 INFO memory | grep used_memory_human

# Commandes par seconde
redis-cli -p 7001 INFO stats | grep instantaneous_ops_per_sec

# Hit ratio du cache
redis-cli -p 7001 INFO stats | grep keyspace

# Requêtes lentes
redis-cli -p 7001 SLOWLOG GET 10

# Fragmentation mémoire
redis-cli -p 7001 INFO memory | grep mem_fragmentation_ratio

# État du cluster
redis-cli -p 7001 CLUSTER INFO
```

---

### **Optimisations clés**

| Paramètre | Valeur | Justification |
|-----------|--------|---------------|
| `cluster-node-timeout` | 3000ms | Détection rapide de panne |
| `appendonly` | yes | Persistance sans perte |
| `cluster-replicas` | 2 | Haute redondance |
| ACL prefix `app:*` | — | Isolation données |
| `--cluster-yes` | — | Automatisation déploiement |

---

### **Bonnes pratiques démontrées**

1. **ACL + TLS** : Authentification obligatoire, utilisateurs séparés
2. **Pas de `default` tout-puissant** : Principe du moindre privilège
3. **2 réplicas** : Résilience au-delà du minimum (1)
4. **AOF** : Meilleure garantie de durabilité vs RDB
5. **Conteneurisation** : Reproductible, portable, versionné
6. **Double monitoring** : redis-stat + RedisInsight

---

### **Procédure de reprise après incident**

```bash
# 1. Diagnostiquer
docker ps | grep redis
redis-cli -c -p 7001 CLUSTER NODES

# 2. Identifier les nœuds down
redis-cli -c -p 7001 CLUSTER NODES | grep fail

# 3. Redémarrer un nœud
docker restart redis-master-1

# 4. Vérifier la resynchronisation
redis-cli -c -p 7001 CLUSTER INFO
# cluster_state:ok ✅

# 5. Rééquilibrer les slots si nécessaire
redis-cli --cluster rebalance redis-master-1:7001 \
  --user admin -a Admin@Cluster2026
```

---

### **Récapitulatif**

| Aspect | Ce qui est en place |
|--------|-------------------|
| **Déploiement** | 9 nœuds Docker, Redis 7.0, cluster automatisé |
| **Sécurité** | 5 utilisateurs ACL, authentification partout |
| **Réplication** | 2 slaves par master, failover automatique |
| **Distribution** | 16 384 hash slots sur 3 masters |
| **Persistance** | AOF activé sur tous les nœuds |
| **Monitoring** | redis-stat (web) + RedisInsight (GUI) |
| **Reprise** | Scripts de diagnostic + restart automatisé |

---

# **Questions ?**

### Merci pour votre attention

```
docker compose -p "redis-cluster" up -d
```
