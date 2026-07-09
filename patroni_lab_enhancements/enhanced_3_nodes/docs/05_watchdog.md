# Watchdog (softdog) — optional host-dependent scenario

## The problem watchdog solves

All demotion logic in the other scenarios assumes Patroni is *running* and
merely disconnected. A different failure class: the Patroni process (or the
whole node) hangs — SIGSTOP, OOM-kill of Patroni but not PostgreSQL,
scheduler starvation, kernel I/O stall. PostgreSQL may keep accepting writes
while Patroni cannot refresh the leader key; after `ttl` another node
promotes, and now two writable primaries exist until the hung node recovers.
The watchdog is the local self-fencing layer that closes this gap: if
Patroni does not pet the device in time, the kernel resets the node.

## Lab setup (Linux host required)

    # on the Docker host - soft_noboot=1 logs instead of rebooting (demo-safe)
    sudo modprobe softdog soft_noboot=1

Then in `docker-compose.yml` uncomment the `devices:` mapping in the Patroni
anchor and set in `patroni.yml.tmpl`:

    watchdog:
      mode: automatic      # or "required" for strict production semantics
      device: /dev/watchdog
      safety_margin: 5

## The arithmetic to teach

Patroni sets the watchdog timeout so the device fires *before* the leader
key expires: the node is guaranteed dead before anyone else can become
primary. With `safety_margin: 5` and `ttl: 30`, the watchdog fires at
`ttl - safety_margin` = 25 s after the last keepalive. `safety_margin: -1`
means "fire at `ttl // 2`". If the platform cannot set the requested
timeout, `mode: required` refuses leadership, `mode: automatic` degrades
with a warning — the difference between the two is a good exam question.

## Demonstration

    # freeze Patroni (not PostgreSQL) on the leader:
    docker compose exec <leader> pkill -STOP -f 'bin/patroni'

Without watchdog: after `ttl`, a replica promotes while the frozen node's
PostgreSQL is still up — inspect it and discuss the exposure window. With
softdog in `soft_noboot=1` mode: the kernel logs the firing (`dmesg | grep
-i softdog` on the host) at the moment it would have reset the node — the
timing relative to the promotion is the entire lesson.
