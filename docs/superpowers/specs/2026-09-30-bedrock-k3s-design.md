# Minecraft Bedrock servers on k3s — design

Date: 2026-09-30
Status: Draft, awaiting review

## Goal

Host the Minecraft Bedrock Edition servers that previously ran under LinuxGSM on a VPS on the
existing k3s cluster, in the `minecraft-servers` namespace, managed as Kustomize manifests in this
repository. Players connect over the public internet, including Xbox consoles via the public
BedrockConnect DNS service.

Success means: players join the migrated world with progress intact, the world survives pod
restarts, and adding or migrating further servers is a documented, repeatable procedure.

## Scope

In scope for this iteration:

- Reusable Kustomize base for a single Bedrock server.
- First server: `daan`, migrated from `~/Downloads/mc-backup/mcserverdaan`.
- Traefik UDP entrypoint configuration.
- World restore helper script.
- README with server list and procedures for creating and migrating servers.

Out of scope (possible follow-ups):

- Migrating the other backups (`mcbserver`, `mcbcreative`, `mcbcreative2`, `mc2026`, `mcbflat1`).
- Automated backups of server data.
- IPv6 exposure.
- Self-hosted BedrockConnect.

## Cluster facts (verified 2026-09-30)

- Single node `vmi3367741`, k3s `v1.35.5+k3s1`, public IP `13.140.175.141`.
- Traefik chart `39.0.7` (Traefik `v3.6.13`), `LoadBalancer` service bound to the node IP via
  k3s ServiceLB.
- CRD `ingressrouteudps.traefik.io` present.
- No existing `HelmChartConfig` for Traefik.
- Namespace `minecraft-servers` already exists.
- Default storage: `local-path`.

## Key constraint: no hostname routing for Bedrock

Bedrock uses RakNet over UDP. Its handshake carries no hostname, so Traefik (or any proxy) cannot
route several servers on one port by name. Each server therefore gets its own public UDP port,
backed by a dedicated Traefik UDP entrypoint. Players, including console players using
BedrockConnect, enter address plus port.

## Architecture

```
player ──UDP :19332──▶ node 13.140.175.141 (ServiceLB)
        ──▶ Traefik entrypoint "mc-daan" (UDP 19332)
        ──▶ IngressRouteUDP bedrock-daan
        ──▶ Service bedrock-daan (ClusterIP, UDP 19132)
        ──▶ Pod bedrock-daan (BDS on 19132, /data on PVC)
```

## Repository layout

```
cluster/
  traefik-helmchartconfig.yaml   # kube-system; one UDP port entry per server
base/
  kustomization.yaml
  deployment.yaml
  pvc.yaml
  service.yaml
  ingressrouteudp.yaml
servers/
  daan/
    kustomization.yaml
    patch.yaml
scripts/
  restore-world.sh
README.md
```

### `cluster/traefik-helmchartconfig.yaml`

`HelmChartConfig` named `traefik` in `kube-system`. `valuesContent` adds one entry under `ports`
per server:

```yaml
ports:
  mc-daan:
    port: 19332
    exposedPort: 19332
    protocol: UDP
    expose:
      default: true
```

Applied separately from the server kustomizations because it lives in `kube-system` and is shared by
all servers. k3s redeploys Traefik when it changes, so ServiceLB opens the new UDP port on the node.

### `base/`

Generic, name-agnostic resources. Resource names are `bedrock`; overlays add a name suffix.

- **Deployment** `bedrock`: `replicas: 1`, `strategy: Recreate` (the RWO volume must be released
  before a new pod starts). Container `itzg/minecraft-bedrock-server:latest`, UDP port 19132,
  `tty: true`, `stdin: true` so `kubectl attach` gives a server console. Env: `EULA=TRUE`,
  `VERSION=LATEST`. Resources: requests `250m` CPU / `512Mi` memory, limit `2Gi` memory. Volume
  `/data` from the PVC. Readiness/liveness are left out; BDS has no health endpoint, and the image
  offers no UDP probe that does not add a dependency.
- **PersistentVolumeClaim** `bedrock-data`: `local-path`, `ReadWriteOnce`, `5Gi`.
- **Service** `bedrock`: `ClusterIP`, UDP 19132.
- **IngressRouteUDP** `bedrock`: `entryPoints: [mc-placeholder]`, routes to Service `bedrock`
  port 19132. Overlays replace the entrypoint.

### `servers/<name>/`

- `kustomization.yaml`: `namespace: minecraft-servers`, `nameSuffix: -<name>`, common label
  `app.kubernetes.io/instance: <name>`, `resources: [../../base]`, `patches: [patch.yaml]` plus a
  JSON patch replacing the IngressRouteUDP entrypoint with `mc-<name>`.
- `patch.yaml`: strategic merge patch that adds server-specific env to the container.

`nameSuffix` automatically updates references between built-in kinds (the Deployment's
`claimName` becomes `bedrock-data-<name>`). Kustomize does not know the IngressRouteUDP CRD, so its
service reference is set explicitly to `bedrock-<name>` in the overlay's JSON patch, together with
the entrypoint.

### Server `daan`

| Setting | Value |
|---|---|
| Public port | 19332 (its old LinuxGSM port) |
| Entrypoint | `mc-daan` |
| `SERVER_NAME` | `Daan` |
| `LEVEL_NAME` | `Daan` |
| `GAMEMODE` | `adventure` |
| `DIFFICULTY` | `peaceful` |
| `ALLOW_CHEATS` | `true` |
| `MAX_PLAYERS` | `10` |
| `ONLINE_MODE` | `true` |
| `ALLOW_LIST` | `false` |
| `DEFAULT_PLAYER_PERMISSION_LEVEL` | `operator` |
| `LEVEL_SEED` | `888882571486312935` |

Configuration comes only from env vars. The itzg image rewrites `server.properties` from env on
every start, so the old LinuxGSM `server.properties` is not copied.

## World restore

`scripts/restore-world.sh <server> <path-to-world-dir>` performs a one-time restore:

1. Validate that `<path-to-world-dir>` contains `level.dat` and `db/`.
2. Scale `deployment/bedrock-<server>` to 0 and wait for its pod to terminate.
3. Start a helper pod (`busybox`) in `minecraft-servers` mounting PVC `bedrock-data-<server>` at
   `/data`, and wait until it is ready.
4. Refuse to continue if `/data/worlds/<level-name>` already exists, unless `--force` is given
   (prevents overwriting a live world).
5. `kubectl cp` the world directory to `/data/worlds/<level-name>`, where `<level-name>` is the
   basename of the source directory.
6. Delete the helper pod.
7. Scale the deployment back to 1.

The script never modifies the source backup. `allowlist.json` and `permissions.json` are not copied:
allowlist and operator settings are expressed through env (`ALLOW_LIST`, `ALLOW_LIST_USERS`,
`OPS`) so they live in git.

## README requirements

The README must contain:

1. **Overview**: what the repo does, the one-port-per-server constraint and why.
2. **Server list**: table with server name, world name, game mode, public port, connect address
   (`13.140.175.141:<port>`), and source backup. It is updated every time a server is added.
3. **Deploying**: applying the Traefik config and a server overlay.
4. **Creating a new server** (fresh world): step-by-step — pick a free port, add a Traefik port
   entry, copy `servers/daan` to `servers/<name>`, edit name, entrypoint and env, apply, open the
   firewall, add a row to the server list.
5. **Migrating a server from a LinuxGSM backup**: step-by-step — locate
   `serverfiles/worlds/<world>` and read the old `server.properties`, map properties to env vars
   (with a mapping table for the common keys), create the server as above, run
   `scripts/restore-world.sh`, verify logs, add a row to the server list. Notes on worlds with
   add-ons (packs stored inside the world folder travel with it) and on the one-way world upgrade.
6. **Operations**: logs, console via `kubectl attach`, restart, and removing a server (including
   the fact that deleting the PVC deletes the world).
7. **Firewall note**: the VPS host or provider firewall must allow each server's UDP port.

## Verification

1. `kubectl kustomize servers/daan` renders without error, and names/references resolve to
   `bedrock-daan`, `bedrock-data-daan`, entrypoint `mc-daan`.
2. After applying the Traefik config, `kubectl -n kube-system get svc traefik` lists `19332/UDP`.
3. After restore, pod logs show the `Daan` level loading and `Server started.`
4. A RakNet unconnected ping to `13.140.175.141:19332` from outside the cluster gets a pong.
5. User joins from a client and confirms the world is intact.

## Risks and caveats

- **World upgrade is one-way.** `VERSION=LATEST` upgrades the 1.26.0.2 world on first load. The
  original backup in `~/Downloads/mc-backup` is the rollback.
- **No automated backups.** local-path stores data on the single node's disk only.
- **Traefik restart.** Changing the `HelmChartConfig` redeploys Traefik, which briefly interrupts
  HTTP ingress on the cluster.
- **Firewall.** A UFW or provider firewall may block UDP 19332 until opened. This is outside the
  manifests.
