# Linux Watchdog Mechanisms and Their Role in PostgreSQL/Patroni Split-Brain Avoidance

## TL;DR
- A watchdog is a countdown timer that force-resets a machine if userspace stops "petting" it; on Linux this is exposed as the `/dev/watchdog` character device (major 10, minor 130) driven by the `drivers/watchdog/` core framework. For PostgreSQL HA the watchdog is the *only* mechanism that converts "Patroni process died/hung but PostgreSQL keeps serving as primary" into a hard node reset, giving Patroni its absolute split-brain guarantee.
- Patroni's watchdog (`patroni/watchdog/base.py`, `linux.py`) is armed before promotion, pinged (`os.write(fd, b'1')`) only *after* the DCS leader-key renewal in `Ha.update_lock()`, and disarmed on demote/pause; with `mode: required` a node that cannot arm the watchdog refuses to promote and is disqualified from the leader race (`_MemberStatus.watchdog_failed` → `failover_limitation()` returns `'not watchdog capable'`).
- The word "watchdog" is heavily overloaded: pgpool-II's "watchdog" is a *distributed quorum/VIP subsystem between pgpool nodes*, not a kernel device; Pacemaker uses the kernel watchdog through SBD (storage-based death); repmgr and most K8s operators have *no* kernel-watchdog fencing at all and rely on external STONITH scripts or Kubernetes liveness/lease semantics.

---

## Part 1 — Linux Watchdog Software and Hardware Solutions

### 1.1 Kernel watchdog subsystem architecture

The Linux watchdog subsystem lives in `drivers/watchdog/`. Since kernel 3.5 a common core framework (`watchdog_core.c`, `watchdog_dev.c`, header `include/linux/watchdog.h`) provides the userspace interface so individual drivers only implement device-specific operations. Before that, each driver re-implemented its own `file_operations`, ioctl handling, and timeout management.

Userspace interacts through a character device: the legacy `/dev/watchdog` (misc device, major 10, minor 130) and, for systems with multiple watchdogs, `/dev/watchdogN` cdevs (dynamic major, minor 0..N). `id` 0 is special: it gets both the `/dev/watchdog0` cdev and the old `/dev/watchdog` miscdev. `/sys/class/watchdog/watchdogN/` exposes read-only attributes: `state`, `status`, `timeout`, `timeleft`, `nowayout`, `bootstatus`, `identity`, `min_timeout`, `max_timeout`.

**Lifecycle**: opening the device *arms* the timer and starts the countdown. Writing any byte (or issuing `WDIOC_KEEPALIVE`) pets it, resetting the countdown to the full timeout. If the countdown reaches zero without a ping, the watchdog fires — a hardware reset for hardware devices, or `emergency_restart()` for softdog.

**Driver core operations** (`struct watchdog_ops` in `watchdog-kernel-api`): mandatory `start`/`stop`; optional `ping`, `status`, `set_timeout`, `set_pretimeout`, `get_timeleft`, `restart`, `ioctl`. Status bits in `struct watchdog_device.status`:
- `WDOG_ACTIVE` — device is active from the user's perspective (userspace must send heartbeats).
- `WDOG_NO_WAY_OUT` — stores the nowayout setting; if set the watchdog cannot be stopped.
- `WDOG_HW_RUNNING` — hardware timer is running and cannot be stopped; if a driver has no stop function the core sets this and keeps pinging after close.

**The ioctl API** (`Documentation/watchdog/watchdog-api`):
- `WDIOC_GETSUPPORT` — returns the `struct watchdog_info` (options bitmask, firmware_version, 32-byte identity string).
- `WDIOC_GETSTATUS` / `WDIOC_GETBOOTSTATUS` — current status / status at last boot (e.g. `WDIOF_CARDRESET` means the last reboot was watchdog-triggered).
- `WDIOC_KEEPALIVE` — pet the timer (only active when `WDIOF_KEEPALIVEPING` is set); argument ignored. Equivalent to a device write.
- `WDIOC_SETTIMEOUT` / `WDIOC_GETTIMEOUT` — set/get the timeout in seconds. The driver may round to hardware granularity and returns the real value; only supported if `WDIOF_SETTIMEOUT` is set. Core does limit-checking against `min_timeout`/`max_timeout`.
- `WDIOC_SETPRETIMEOUT` / `WDIOC_GETPRETIMEOUT` — pretimeout (an early trigger some seconds *before* the reset, used to capture panic/crashdump data via NMI/interrupt). Pretimeout is "seconds before reset," not "seconds until pretimeout."
- `WDIOC_GETTIMELEFT` — seconds left before reset (needs `get_timeleft` callback else `-EOPNOTSUPP`).
- `WDIOC_SETOPTIONS` — `WDIOS_DISABLECARD` (off), `WDIOS_ENABLECARD` (on), `WDIOS_TEMPPANIC`.
- `WDIOC_GETTEMP` — temperature in degrees Fahrenheit (cards that support it).

**Magic close and NOWAYOUT.** By default, closing `/dev/watchdog` cleanly stops the watchdog. To force an explicit, deliberate disable the userspace program must write the magic character `'V'` to the device before closing — this is the "magic close" feature (`WDIOF_MAGICCLOSE`). If the device is closed *without* first writing `'V'`, the watchdog keeps running and will eventually reset the machine (this protects against a crashing daemon that closes its fd on the way down). The kernel build option `CONFIG_WATCHDOG_NOWAYOUT` (and per-driver `nowayout` module parameter) overrules magic close entirely: once opened, the watchdog can never be disabled — not by clean close, not by magic close, not by `WDIOC_SETOPTIONS`. The nowayout feature always overrules the magic close feature. Write handling and magic-char handling are done centrally by the framework.

### 1.2 Hardware watchdog implementations

- **`iTCO_wdt` (Intel TCO).** The TCO (Total Cost of Ownership) timer built into Intel ICH/PCH chipsets (ICH0..ICH10, 63xxESB, and modern PCH). It is a two-stage timer that reboots after the *second* expiration; timeout set via the `heartbeat` module parameter. Depends on `CONFIG_X86 && CONFIG_PCI`, uses `iTCO_vendor_support`. Common gotcha: "failed to reset NO_REBOOT flag, reboot disabled by hardware" — some BIOSes leave the `NO_REBOOT` flag set so the watchdog cannot actually reboot. Boot log looks like `iTCO_wdt: Found a Intel PCH TCO device (Version=6, TCOBASE=0x0400)` / `initialized. heartbeat=30 sec (nowayout=0)`.
- **`wdat_wdt` (ACPI WDAT).** Firmware-abstracted watchdog described by the ACPI WDAT table (`/sys/firmware/acpi/tables/WDAT`). When present, `wdat_wdt` takes precedence over the native iTCO driver. Enabled/disabled via BIOS "TCO Timer."
- **IPMI watchdog (`ipmi_watchdog`).** Implements the Linux watchdog interface on top of the IPMI message handler talking to the BMC. Module parameters: `timeout`, `pretimeout`, `action` (`reset`/`power_cycle`/`power_down`/`none` → mapped to IPMI "Hard Reset / Power Cycle / Power Down / No action"), `preaction` (`pre_smi`, `pre_int`, `pre_nmi`), `preop` (`preop_none`, `preop_panic`, `preop_give_data`), `start_now`, `nowayout`, `panic_wdt_timeout`. On a pre-action it panics and starts a 120-second reset timer. Critical caveat: if you use the NMI preaction you must NOT also run the kernel NMI (lockup) watchdog — the driver cannot distinguish the source of an NMI and will assume any otherwise-unhandled NMI is from IPMI and panic. Requires writing `'V'` to stop.
- **Server BMC watchdogs (iDRAC, iLO).** On Dell iDRAC the "Automated System Recovery Agent" is the BMC watchdog; on some generations (e.g. R610) the iDRAC watchdog and the IPMI watchdog are the *same* device, and enabling one may be required for `bmc-watchdog --set` to succeed. Action typically "Power Cycle." (Note IBM/Lenovo BMC bug: log records "Hard Reset" instead of "Power Cycle" after recovery.)
- **`sp5100_tco` (AMD)** — the AMD/ATI SP5100/SB7xx southbridge TCO analog of iTCO.
- **`hpwdt` (HPE)** — HPE ProLiant iLO watchdog, one of the most common server watchdog drivers.
- **`mei_wdt`** — watchdog exposed over the Intel Management Engine Interface.
- **Embedded/SoC**: `imx2-wdt` (NXP i.MX2/i.MX6, default 60 s reset), `rn5t618-wdt` (i.MX7 PMIC, default 128 s), `bcm2835_wdt` (Raspberry Pi), the ARM SBSA generic watchdog (`sbsa_gwdt`) mandated by the ARM Server Base System Architecture, and many `*_wdt` SoC drivers. Toradex etc. commonly ship with `CONFIG_WATCHDOG_NOWAYOUT` unset by default.
- **Hypervisor/virtual**: `i6300esb` — QEMU/KVM emulates the Intel 6300ESB PCI watchdog (`hw/watchdog/wdt_i6300esb.c`); libvirt `<watchdog model='i6300esb' action='reset'/>` where action ∈ `reset` (default), `shutdown`, `poweroff`, `pause`, `none`, `dump`. `shutdown` is discouraged because it needs ACPI response which a hung guest can't provide. `xen_wdt` uses the Xen hypercall watchdog; VMware/Hyper-V provide their own. The guest kernel needs `CONFIG_I6300ESB_WDT`; on expiry QEMU calls `watchdog_perform_action()`.

**Behavior on expiry.** Hardware watchdogs perform a hard reset (equivalent to the reset button / power cycle), independent of CPU/kernel state — this is why they can recover a fully wedged kernel. Devices with pretimeout can fire an NMI/interrupt first to grab a crashdump. IPMI/BMC watchdogs can be configured for hard reset, power cycle, or power down.

### 1.3 The softdog module

`drivers/watchdog/softdog.c` (originally "SoftDog 0.05," Alan Cox, 1995–96) is a pure-software watchdog built on a kernel timer/hrtimer. On timeout it calls `emergency_restart()` (or `schedule_work()`→`kernel_restart()` in newer variants). Module parameters:
- `soft_margin` — timeout in seconds, `0 < soft_margin < 65536`, default 60.
- `nowayout` — cannot be stopped once started (default = `CONFIG_WATCHDOG_NOWAYOUT`).
- `soft_noboot` — set to 1 to *not* reboot (just log to the kernel ring buffer, visible via `dmesg`), 0 to reboot. Invaluable for testing.
- `soft_panic` — set to 1 to panic instead of reboot.
- `soft_reboot_cmd` / `soft_active_on_boot` — newer options to set a custom reboot command and arm the watchdog immediately at module load.

**Guarantees and limits.** softdog survives userspace hangs, OOM, and most application-level failures because the kernel timer keeps running. It does *not* protect against a fully wedged kernel: if timer interrupts stop firing (hard lockup, scheduler deadlock), softdog — being code on the same CPU that just died — cannot fire. In VMs, if the hypervisor pauses/suspends the guest, the guest's virtual clock is frozen, so softdog's timer does not advance during the pause; the reset happens only after resume. For real fencing guarantees, ClusterLabs' *Using SBD With Pacemaker* guide is explicit: "While it is possible to specify a software watchdog, software watchdogs rely on a correctly functioning operating system, and thus are unreliable for fencing purposes. Always use a hardware watchdog device in production. (Many server motherboards have them built in.)" For Patroni's use case, though, the Patroni documentation states the opposite trade-off is acceptable: "For most use cases using software watchdog built into the Linux kernel is secure enough" — because the failure it most needs to cover is a dead/hung *Patroni process* while the kernel is otherwise healthy.

### 1.4 Kernel lockup detectors (a distinct concept)

These are internal *self-diagnostics* that panic/warn the kernel; they are NOT the userspace-serviced `/dev/watchdog` and require no petting from userspace. Documented in `Documentation/admin-guide/lockup-watchdogs.rst`, implemented in `kernel/watchdog.c`.
- **Soft lockup detector** — detects a task looping in kernel mode >2×`watchdog_thresh` seconds (softlockup threshold; default `watchdog_thresh`=10 → 20 s) without yielding. Built on an hrtimer (period `2*watchdog_thresh/5` ≈ 4 s) plus a high-priority per-CPU `watchdog/N` thread that bumps a timestamp. Sysctls: `kernel.watchdog`, `kernel.watchdog_thresh`, `kernel.softlockup_panic`, `kernel.softlockup_all_cpu_backtrace`, `kernel.watchdog_cpumask`.
- **Hard lockup detector (NMI watchdog)** — detects a CPU looping with interrupts disabled. On architectures with perf/PMU it uses an NMI perf event; otherwise the SMP "buddy" detector has each CPU watch a buddy's hrtimer interrupt count (missed-interrupt threshold 3). Sysctls/params: `nmi_watchdog=`, `kernel.nmi_watchdog`, `kernel.hardlockup_panic`. Note NMI watchdog is often unreliable in VMs and is disabled by some hypervisors.
- **Hung task detector** — flags tasks stuck in uninterruptible `D` state for `kernel.hung_task_timeout_secs`; `kernel.hung_task_panic` makes it panic. Gated on `CONFIG_DETECT_HUNG_TASK`.

These can be combined with `kernel.panic` (panic→reboot timeout) and `panic_on_oops` to auto-reboot. They complement but do not replace `/dev/watchdog`: a soft/hard-lockup panic still relies on the kernel being able to reboot itself, whereas a hardware `/dev/watchdog` reset does not.

### 1.5 Userspace watchdog daemons and systemd

**`watchdog(8)` daemon** (the `watchdog` package, config `/etc/watchdog.conf`). Opens `/dev/watchdog` and pings it every `interval` seconds (default 1; must be < the kernel driver's timeout, typically ~60 s) while running a battery of health checks; if any fails the machine is rebooted/halted. Tests include: `max-load-1/5/15` (load average), `min-memory`/`allocatable-memory` (free/allocatable pages), `max-temperature`, `file` + `change` (file mtime/staleness, e.g. on NFS), `pidfile` (process liveness), `ping` (ICMP to one or more IPs), `interface` (passive traffic monitoring), plus `test-binary`/`repair-binary` and a directory of test/repair scripts (`/etc/watchdog.d`, called with `test` or `repair` argument; exit 0 = OK). `realtime = yes` + `priority` locks the daemon into memory. `wd_keepalive` is a lightweight companion that only pets the device (no health checks) — used while the full daemon is stopped/restarting so the hardware stays armed.

**systemd** (since v183; Lennart Poettering, "systemd for Administrators, Part XV"). Two layers:
- **Hardware/runtime watchdog**: `RuntimeWatchdogSec=` in `/etc/systemd/system.conf` makes PID 1 open `/dev/watchdog` and ping it at half the interval; if systemd or the kernel hang, the hardware resets the box. `RebootWatchdogSec=` (formerly `ShutdownWatchdogSec=`) arms a watchdog during reboot; `WatchdogDevice=` selects the device; `RuntimeWatchdogPreSec=` sets a pre-timeout.
- **Per-service software watchdog**: a `Type=notify` service with `WatchdogSec=` must call `sd_notify(0, "WATCHDOG=1")` every ≤½ interval (the interval is exported as `WATCHDOG_USEC`). Missing the ping puts the service in failure state; combine with `Restart=on-watchdog`/`on-failure`, `WatchdogSignal=` (e.g. SIGABRT for a coredump), and `StartLimitBurst`/`StartLimitIntervalSec`/`StartLimitAction=reboot-force` for escalation. `WATCHDOG=trigger` forces the action immediately.

**Hierarchy**: hardware watchdog ← systemd (PID 1) ← individual services. Crucially, `/dev/watchdog` is single-open: only one process can hold it. So systemd's `RuntimeWatchdogSec` and a separate daemon (or Patroni) cannot both use the *same* device — see §2.8.

### 1.6 Common use cases and fencing theory

**Use cases**: embedded/IoT and unattended remote systems (reboot on hang with no operator), automotive/industrial safety, ensuring reboot on kernel panic/hang, and — the focus here — **HA cluster fencing via self-fencing/suicide**. Watchdog multiplexing (one device, many apps) is handled by a single arbiter (systemd, watchdog daemon, or a mux like Proxmox's `watchdog-mux`) that pings the device on behalf of many supervised units.

**Fencing theory.** Fencing = guaranteeing a suspect node cannot touch shared state before recovering its role elsewhere. Two families:
- **External fencing / STONITH ("Shoot The Other Node In The Head")**: a *peer* forcibly powers off/reboots the suspect via an out-of-band device — `fence_ipmilan`, PDU, `fence_pve`, cloud APIs (`fence_ecloud`, `fence_aws`). Reliable but depends on the fencing path being reachable (the classic failure: the DC hosting both the node and its fence device loses power).
- **Self-fencing / node suicide**: the node fences *itself* using a local watchdog. If it loses quorum or can't confirm its role, it stops petting the watchdog and the hardware reboots it. No peer action needed, works even when the node is network-isolated.

**Why leases + watchdog together give a guarantee.** A lease (leader lock with TTL in a DCS) says "you may act as primary until time T." A watchdog says "if I haven't confirmed my lease by time T−margin, reboot me." Together they bound the worst case: either the node renews its lease (and stays primary) or it is guaranteed to be gone (reset) before any other node can safely take the lease — closing the window in which two nodes could both be primary.

**SBD (Storage-Based Death) in Pacemaker.** `sbd` combines a watchdog with (optionally) shared block storage. Each node runs `sbd` which feeds the watchdog; if it stops feeding (I/O error, lost quorum, Pacemaker says fence), the hardware resets the node. Modes:
- **Disk-based**: a small shared LUN holds a slot per node (up to 255). A peer writes a "poison pill" (exit/reset message) to the target's slot; the target's `sbd` reads it and self-fences. `msgwait` timeout must be ≥ 2× watchdog timeout. Works even in two-node clusters.
- **Diskless**: no shared disk — purely watchdog + Corosync quorum. A node self-fences on loss of quorum, loss of a monitored daemon, or on Pacemaker's fence request. Requires ≥3 nodes (or 2 + QDevice/QNetd) because a two-node diskless cluster cannot resolve split-brain. Corosync traffic must not be firewalled (even loopback).

ClusterLabs stresses: always use a *hardware* watchdog for SBD in production; `stonith-watchdog-timeout` must be set only after `sbd` is running on every node.

---

## Part 2 — Watchdogs in the PostgreSQL / Patroni Ecosystem

### 2.1 Why Patroni needs a watchdog

Patroni prevents split-brain in layers: (1) at the Patroni layer a node must hold the DCS **leader key** (a lease with TTL) before running as primary, and demotes itself if it cannot renew it; (2) the DCS (etcd/Consul/ZooKeeper/K8s) uses a consensus algorithm (Raft, etc.) so only one node holds the key; (3) at the OS/hardware layer the **watchdog** performs STONITH-by-suicide. Layers (1)–(2) assume a *live, scheduled, correctly-clocked* Patroni process. The watchdog exists precisely for when that assumption breaks. Per the Patroni docs, the demote-on-lock-loss path "may fail to happen" because:
- Patroni crashed (bug, OOM killer, or a sysadmin `kill -9`).
- PostgreSQL shutdown is too slow (shutdown checkpoint longer than the TTL).
- Patroni doesn't get to run: high load/CPU starvation, the VM being paused by the hypervisor, Python GC/GIL pauses, `fsync()` blocked on stalled storage, or a system clock jump.

In every one of these, the leader key can expire in the DCS (so a replica gets promoted) while the *old* primary's PostgreSQL keeps accepting writes — classic split-brain. The watchdog covers each: if Patroni isn't running its loop to pet the device, the box resets before/at TTL expiry. As Ants Aasma (who wrote much of Patroni's watchdog code) framed it in the original design (issue #239): "When Patroni dies or wedges itself split brain protection is not guaranteed. Adding watchdog support would give reasonably good guarantees of PostgreSQL master going away when Patroni dies. Watchdog driver will ensure that the server gets rebooted when the heartbeat stops."

### 2.2 Patroni's watchdog module: structure

`patroni/watchdog/` contains `base.py` (the `Watchdog` facade + `WatchdogConfig`, `WatchdogBase`, `NullWatchdog`) and `linux.py` (`LinuxWatchdogDevice`, `TestingWatchdogDevice`, `WatchdogInfo`).

**Config** (`WatchdogConfig` in `base.py`): reads the `watchdog` section — `mode` (`off`/`automatic`/`required`, parsed by `parse_mode`; default `automatic`), `device` (default `/dev/watchdog`), `safety_margin` (default 5), `driver` (default `default`). It also captures `ttl` and `loop_wait` from the main config. `get_impl()` returns `LinuxWatchdogDevice` on Linux with the default driver, `TestingWatchdogDevice` for the testing driver, else `NullWatchdog`. If `mode == required` and the platform can't support a watchdog (`impl.is_null`), Patroni logs "Configuration requires a watchdog, but watchdog is not supported on this platform." and calls `sys.exit(1)`.

**Timeout calculation** (`WatchdogConfig.timeout`):
```python
@property
def timeout(self) -> int:
    if self.safety_margin == -1:
        return int(self.ttl // 2)
    else:
        return self.ttl - self.safety_margin
```
And `timing_slack = timeout - loop_wait`. If `timing_slack < 0` (i.e. `ttl < 2×loop_wait`) the watchdog is refused with "Watchdog not supported because leader TTL … is less than 2x loop_wait …".

### 2.3 Patroni's `LinuxWatchdogDevice` (linux.py) — code-level detail

`linux.py` reimplements the relevant parts of `linux/ioctl.h` and `linux/watchdog.h` in pure Python via `ctypes`/`fcntl`. The ioctl-number helpers are `IOC`, `IOR`, `IOW`, `IOWR` (Python equivalents of the C `_IOC/_IOR/_IOW/_IOWR` macros), built from `IOC_NONE/IOC_WRITE/IOC_READ` and the bit-field shift constants (with special cases for mips/sparc/powerpc/parisc). The constants are derived, not hard-coded:
```python
WATCHDOG_IOCTL_BASE = 'W'
WDIOC_GETSUPPORT   = IOR(WATCHDOG_IOCTL_BASE, 0, struct_watchdog_info_size)
WDIOC_GETSTATUS    = IOR(WATCHDOG_IOCTL_BASE, 1, int_size)
WDIOC_GETBOOTSTATUS= IOR(WATCHDOG_IOCTL_BASE, 2, int_size)
WDIOC_SETOPTIONS   = IOR(WATCHDOG_IOCTL_BASE, 4, int_size)
WDIOC_KEEPALIVE    = IOR(WATCHDOG_IOCTL_BASE, 5, int_size)
WDIOC_SETTIMEOUT   = IOWR(WATCHDOG_IOCTL_BASE, 6, int_size)
WDIOC_GETTIMEOUT   = IOR(WATCHDOG_IOCTL_BASE, 7, int_size)
```
The `WDIOF` dict carries the option bits (`SETTIMEOUT=0x0080`, `MAGICCLOSE=0x0100`, `KEEPALIVEPING=0x8000`, etc.), and `WatchdogInfo` (a `NamedTuple` of `options`, `version`, `identity`) provides `has_MAGICCLOSE`/`has_SETTIMEOUT`/`has_KEEPALIVEPING` convenience flags by masking `options`.

Key methods (behavior confirmed from source):
- `open()` → `self._fd = os.open(self.device, os.O_WRONLY)`. Opening arms the device.
- `keepalive()` → `os.write(self._fd, b'1')`. **Notably Patroni pings by writing the byte `'1'`, NOT via the `WDIOC_KEEPALIVE` ioctl** (the constant is defined but unused for petting). Any non-`'V'` byte pets the watchdog.
- `close()` → `os.write(self._fd, b'V')` then `os.close(self._fd)`. This is the **magic-close**: Patroni deliberately writes `'V'` to gracefully disable the watchdog on clean demote/exit.
- `can_be_disabled` → `get_support().has_MAGICCLOSE` — whether the device honors magic close (nowayout devices return False).
- `set_timeout(t)` → `_ioctl(WDIOC_SETTIMEOUT, ctypes.c_int(t))`, valid `0 < t < 0xFFFF`; `get_timeout()` → `WDIOC_GETTIMEOUT`; `get_support()` → `WDIOC_GETSUPPORT` (cached). `has_set_timeout()` → `has_SETTIMEOUT`.
- `is_running` → `self._fd is not None`; `is_healthy` → `os.path.exists(device) and os.access(device, os.W_OK)`.
- `_ioctl()` uses `fcntl.ioctl(self._fd, func, arg, True)`.

`TestingWatchdogDevice` overrides `set_timeout`/`get_timeout`/`get_support` to translate ioctls into ordinary writes (`Ctimeout=<n>`) that a test harness can intercept via a named pipe — this backs the `driver: testing` option and validation paths.

### 2.4 The keepalive/lock-renewal tie-in (ha.py)

This is the heart of the guarantee. In `Ha.update_lock()` the watchdog is pinged **only after** the DCS leader key is successfully updated:
```python
def update_lock(self, update_status=False):
    ...
    ret = self.dcs.update_leader(self.cluster, last_lsn, slots, self._failsafe_config())
    ...
    self.set_is_leader(ret)
    if ret:
        self.watchdog.keepalive()
    return ret
```
So each HA loop iteration: renew the lease in the DCS → if and only if that succeeded, pet the watchdog. If the DCS update fails (or Patroni never reaches this code because it's dead/hung), the watchdog is *not* pinged and will fire. The `update_lock` docstring makes the ordering explicit: "Last, but not least, this method calls a `Watchdog.keepalive` method after the leader key was successfully updated." `safety_margin` is the budget reserved for the gap between the confirmed lease renewal and the keepalive write; if Patroni is suspended at exactly the wrong moment for longer than the margin, the keepalive could slip past lease expiry — hence the `safety_margin: -1` (→ `ttl//2`) option for an absolute guarantee.

**Activation before promotion.** `Watchdog.activate()` (`base.py`) opens the device and sets the timeout; it is called before a node promotes. If a safe timeout can't be configured and `mode == required`, `activate()` returns `False` and the node refuses to promote ("Configuration requires watchdog, but a safe watchdog timeout … could not be configured"). If the device can't be disabled (nowayout) Patroni warns "Watchdog implementation can't be disabled. Watchdog will trigger after Patroni loses leader key."

**Disarm on demote/pause.** On demotion, `demote()` passes `on_safepoint=self.watchdog.disable if self.watchdog.is_running else None` to `state_handler.stop()`, so the watchdog keeps being pet during a long shutdown checkpoint and is disabled precisely at the safepoint (once client connections are terminated) — avoiding a spurious reset while still guaranteeing safety. `recover()` calls `self.watchdog.disable()` before failing over or restarting as a standby (the watchdog is only needed while primary). The watchdog is also disabled while Patroni is paused.

### 2.5 `required` mode and the leader race

Each member's REST API status includes a `watchdog_failed` field. In `ha.py`, `_MemberStatus.watchdog_failed` is read from that JSON ("indicates that watchdog is required by configuration but not available or failed"), and `failover_limitation()` returns reasons a node can't promote:
```python
def failover_limitation(self):
    if not self.reachable:
        return 'not reachable'
    if self.nofailover:
        return 'not allowed to promote'
    if self.watchdog_failed:
        return 'not watchdog capable'
    return None
```
So in `required` mode a node whose watchdog can't be armed advertises `watchdog_failed=True` and is disqualified from the leader race by its peers — it will not be chosen as a failover candidate. This prevents the pathological case of promoting a node that has no fencing protection.

### 2.6 The HA-loop time budget

With defaults `ttl=30`, `loop_wait=10`, `retry_timeout=10`, `safety_margin=5`:
- Watchdog timeout = `ttl − safety_margin` = 25 s.
- HA loop has `ttl − safety_margin − loop_wait` = 15 s to complete a cycle before reset.
- On DCS unavailability, `ttl − safety_margin − loop_wait − retry_timeout` = 5 s to terminate all client connections before the box resets.

Setting `safety_margin: -1` makes the timeout `ttl//2` = 15 s, guaranteeing the watchdog fires before lease expiry under all scheduling delays; the docs recommend then increasing `ttl` and/or reducing `loop_wait`/`retry_timeout`. Tighter tuning (e.g. `ttl:20, loop_wait:5, retry_timeout:5, safety_margin:3`) yields sub-25 s failover but demands that every component (DCS latency, network RTT, PostgreSQL responsiveness) reliably fits inside the smaller windows.

### 2.7 Deployment: softdog for Patroni

Per the Patroni docs, softdog is "secure enough" for most cases. Setup as root before starting Patroni:
```bash
modprobe softdog                 # optionally soft_noboot=1 for testing (logs instead of resets)
chown postgres /dev/watchdog     # or a udev rule granting the patroni user access
```
A udev rule is cleaner than chown (survives device recreation), e.g. `KERNEL=="watchdog", OWNER="postgres"`. To auto-load softdog: `/etc/modules-load.d/softdog.conf`. Patroni config:
```yaml
watchdog:
  mode: required        # off | automatic | required
  device: /dev/watchdog
  safety_margin: 5      # or -1 for ttl//2 absolute guarantee
```
On bare metal you may prefer the real hardware watchdog (`iTCO_wdt`, `hpwdt`, IPMI). If both a hardware driver and softdog register devices, be explicit about which `/dev/watchdogN` Patroni uses, and blacklist conflicting/auto-loaded modules if the wrong one grabs `/dev/watchdog`. In VMs, add an `i6300esb` device (`<watchdog model='i6300esb' action='reset'/>`) for a truer hardware-like reset than softdog under hypervisor pause.

### 2.8 Known issues and pitfalls

- **systemd `RuntimeWatchdogSec` vs Patroni both wanting `/dev/watchdog`.** `/dev/watchdog` is single-open. If systemd's runtime watchdog already holds it, Patroni's `open()` fails; if Patroni holds it, systemd's runtime watchdog silently won't take effect. Solutions: give each its own device (e.g. hardware watchdog → systemd, `softdog` → Patroni, or vice-versa via `WatchdogDevice=`), or don't enable both on the same device.
- **NOWAYOUT kernels.** If the kernel/driver is built with `CONFIG_WATCHDOG_NOWAYOUT` (or `nowayout=1`), Patroni's magic-close `'V'` can't disarm it; `can_be_disabled` is False and Patroni warns that the box will reset after leader-key loss even on graceful demote. Acceptable for pure fencing but surprising in testing.
- **Containers/Kubernetes.** Accessing `/dev/watchdog` from a pod requires a privileged/host-device mount and is generally discouraged; softdog is a *host-kernel* module (a pod can't `modprobe` it and a pod-local watchdog would only reset the pod's netns, not fence the node). This is why Patroni-on-K8s typically runs `mode: off` and leans on K8s primitives + the DCS. (See §2.12.)
- **Spurious/"false" resets** during heavy testing or long stop-the-world events are expected with `mode: required`; that annoyance is the price of the guarantee.
- **Multiple processes on one device** (watchdog daemon + Patroni, or two Patronis) will collide on the single-open device.

### 2.9 Testing watchdog behavior safely

- `modprobe softdog soft_noboot=1` → the watchdog logs to `dmesg` instead of rebooting; verify the timeout counts down without killing the box.
- Arm and observe: open `/dev/watchdog`, stop petting, watch `wdctl` / `/sys/class/watchdog/watchdog0/timeleft`. (Note: running `wdctl` can *disarm* a non-nowayout watchdog — don't run it against a production-armed device.)
- Real failover test: `kill -9` the Patroni process on the primary and confirm the node resets ~at `ttl − safety_margin`; a replica should promote. On K8s use the liveness probe path instead.
- Force a kernel path: `echo c | sudo tee /proc/sysrq-trigger` (panic) to validate that a hardware watchdog recovers a wedged kernel (softdog cannot).
- The `driver: testing` harness lets you unit-test timeout math without a real device.

### 2.10 pgpool-II "watchdog" — a completely different thing

pgpool-II's **watchdog** is *not* a kernel `/dev/watchdog` device. It is a distributed coordination subsystem among multiple pgpool-II instances providing HA for pgpool itself: leader ("master") election, a shared/delegate **virtual IP** (VIP) that must live on exactly one node, quorum, and consistency checks. Terminology collision only.

How it works (`pgpool.conf`): `use_watchdog = on`, each node identified by `wd_hostname`/`pgpool_node_id`. Health of peer pgpool nodes is checked by **lifecheck** (`wd_lifecheck_method`):
- `heartbeat` (default/recommended): UDP heartbeat packets (`wd_heartbeat_keepalive`, `wd_heartbeat_deadtime`, `heartbeat_hostnameN/portN/deviceN`).
- `query`: sends `wd_lifecheck_query` (`SELECT 1`) to peers; deprecated, and requires enough `num_init_children`.
- `external`: delegates lifecheck to a third-party system (since v3.5).

The leader brings up the VIP (`if_up_cmd`/`if_down_cmd`/`arping_cmd`, needing root or setuid/sudo). Watchdog coordinates that failback/failover/`follow_master` run on only one node, and uses a **quorum** to avoid VIP conflicts. **Its own split-brain**: with an even number of nodes a network partition can produce two leaders each with quorum; hence pgpool requires an **odd number ≥ 3** of watchdog nodes (`enable_consensus_with_half_votes` tunes half-vote behavior). Historically, when a watchdog process died abnormally the VIP could come up on both old and new active nodes. So pgpool's watchdog protects *pgpool's* availability and VIP uniqueness; it does not fence the PostgreSQL host and offers no kernel-level split-brain guarantee for the database itself.

### 2.11 Pacemaker/Corosync PostgreSQL clusters

Two common resource agents: **PAF (PostgreSQL Automatic Failover)** `pgsqlms` (multistate) and the older `pgsql` RA. Fencing is delegated to Pacemaker STONITH: `fence_ipmilan`, `fence_pve`, cloud/`fence_*` agents, or **SBD** (§1.6). PAF's documentation is emphatic: "DO NOT BUILD A CLUSTER WITHOUT PROPER, WORKING AND TESTED FENCING." Compared to Patroni:
- Patroni: application-level leader lease in a DCS + optional self-fencing watchdog; no shared storage needed; DCS is the source of truth.
- Pacemaker+PAF/pgsql: Corosync membership/quorum + Pacemaker policy engine + mandatory STONITH (power fencing or SBD watchdog). SBD diskless mode is effectively the same self-fencing-by-watchdog idea Patroni uses, and disk-based SBD adds a shared-storage poison pill. Quorum + SBD + watchdog is the belt-and-suspenders combination.

### 2.12 Other PostgreSQL tools

- **repmgr**: has *no built-in fencing/STONITH*. `repmgrd` promotes via `promote_command` and relies on user scripts. The documented pattern fences a failed primary by rewriting **PgBouncer** configs over SSH — but as community threads note, this depends on messages being *received*; if the old primary/DC was unreachable at failover time it can come back as a second primary → split brain. repmgr 4.4+ added primary-side visibility knobs (`child_nodes_connected_min_count`, `child_nodes_connected_include_witness`, `child_nodes_disconnect_command`) so an isolated primary can run a self-fencing script (VIP removal, port change, `pg_hba` lockdown, shutdown, or poweroff). Consensus needs ≥3 nodes (a witness). Still, fencing quality is entirely operator-supplied.
- **pg_auto_failover**: a monitor + keeper (formation) model. The monitor is the arbiter of state transitions; it uses a health-check + FSM rather than a kernel watchdog. It has no `/dev/watchdog` self-fencing; safety comes from the monitor serializing role changes (and its own HA is a concern). Fencing of a truly isolated primary is not a watchdog-grade guarantee.
- **CloudNativePG / K8s operators**: replace watchdog semantics with Kubernetes primitives. CNPG "fencing" is an *administrative* action via the `cnpg.io/fencedInstances` annotation (shuts down the postmaster while keeping the pod) — not automatic isolation response. For network-partition split-brain, CNPG historically relied on a per-cluster **lease** that serializes promotion, and added an isolation-aware primary liveness probe: the liveness pinger was "introduced experimentally in 1.26" and made "a stable feature" in **1.27** with `.spec.probes.liveness.isolationCheck` enabled by default, so the liveness probe performs primary isolation checks. Per the 1.27 release notes, "The default behavior of the liveness probe has been updated. An isolated primary is now forcibly shut down within the configured `livenessProbeTimeout` (default: 30 seconds)" — with the default failure threshold deriving as `livenessProbeTimeout/periodSeconds = 30/10 = 3`. On restart, the instance manager refuses to start PostgreSQL while still isolated — a Kubernetes-native "self-fence." Synchronous replication is the real protection (an isolated primary can't ack commits). Quorum-based failover shipped experimental in 1.27 (stable targeted for 1.28). This is weaker than a hardware watchdog: the kubelet must be alive and the node must be reachable to K8s.
- **Stolon**: sentinel/keeper/proxy model; the proxy fences by refusing to route to a non-leader (connection-level), not a kernel watchdog.
- **keepalived + VIP**: VRRP moves a VIP; it is *not* fencing — it does nothing to stop the old primary's PostgreSQL from accepting writes from clients that still reach it. VIP failover without fencing is a split-brain risk.
- **PostgreSQL's internal "watchdog" confusion**: the postmaster monitors/reaps its backend processes and restarts after a backend crash — sometimes loosely called a "watchdog." This is *unrelated* to the kernel watchdog or HA fencing.

### 2.13 Comparison table — split-brain protection across the PostgreSQL HA landscape

| Tool / stack | Arbiter of truth | Fencing mechanism | Uses kernel `/dev/watchdog`? | Self-fence on isolation? | Two-node safe? | Notes |
|---|---|---|---|---|---|---|
| **Patroni + watchdog** | DCS leader lease (etcd/Consul/ZK/K8s) | Self-fence: watchdog reset if lease not renewed | **Yes** (softdog or HW) | Yes (`required` mode) | Needs DCS quorum (≥3 DCS) | Strongest app-level guarantee; keepalive only after lease renewal |
| **Patroni (no watchdog)** | DCS leader lease | Demote-on-lock-loss (software only) | No | Only if Patroni is alive & scheduled | Same | Cannot cover crash/hang/OOM/VM-pause/clock-jump |
| **Pacemaker + PAF/pgsql + SBD** | Corosync quorum + Pacemaker | SBD poison pill (disk) and/or watchdog self-fence; or power STONITH | **Yes** (SBD) | Yes (diskless SBD) | Disk-SBD yes; diskless needs ≥3 or QDevice | Mandatory fencing; belt-and-suspenders |
| **Pacemaker + power STONITH** | Corosync quorum | External `fence_ipmilan`/PDU/cloud | No (unless SBD too) | No (peer-driven) | Yes | Depends on fence path reachability |
| **pgpool-II watchdog** | pgpool quorum (odd ≥3) | VIP arbitration among pgpools; no host fencing | No (different concept) | No (for the DB host) | No (needs ≥3) | Protects pgpool HA + VIP uniqueness, not DB fencing |
| **repmgr** | repmgrd + witness | External scripts (PgBouncer rewrite, custom self-fence) | No | Only via user script (4.4+) | Needs witness (≥3) | No built-in STONITH; fencing is DIY |
| **pg_auto_failover** | monitor FSM | Monitor serializes transitions; health checks | No | No watchdog-grade | Monitor is SPOF unless HA | No kernel watchdog |
| **CloudNativePG / K8s operators** | K8s API + per-cluster lease | Admin annotation fencing; liveness-probe self-fence (1.27+); sync repl | No | Yes-ish (kubelet kills isolated primary) | Needs ≥3 for quorum failover | Weaker than HW watchdog; relies on kubelet/API reachability |
| **Stolon** | sentinel + store | Proxy refuses non-leader routing | No | No | Needs store quorum | Connection-level fencing only |
| **keepalived + VIP** | VRRP priority | None (VIP move only) | No | No | No | Not fencing; split-brain risk |

---

## Recommendations

1. **Run Patroni with `watchdog.mode: required` in production on bare metal and VMs.** Without it, Patroni cannot guarantee split-brain avoidance for the crash/hang/OOM/VM-pause/clock-jump class of failures. Accept the operational cost of occasional resets during stress testing. Benchmark that changes: if you observe spurious resets, first confirm they are not real HA-loop overruns (check `loop_wait` timing logs) before relaxing to `automatic`.
2. **Pick the device deliberately.** Prefer a real hardware watchdog (`iTCO_wdt`/`hpwdt`/IPMI) on physical servers; `i6300esb` in KVM/QEMU guests; `softdog` where nothing else is available. Confirm the watchdog can actually reboot (watch for the iTCO `NO_REBOOT` message). Load it via `/etc/modules-load.d/` and grant access via a udev rule, not a one-off `chown`.
3. **Resolve the single-open conflict up front.** Do not enable systemd `RuntimeWatchdogSec` on the same device Patroni uses. Either give systemd the hardware watchdog and Patroni a separate `softdog`, or leave the device entirely to Patroni.
4. **Tune the time budget to your infrastructure.** Start from defaults (`ttl=30, loop_wait=10, retry_timeout=10, safety_margin=5` → 25 s watchdog, 5 s connection-drain budget). For an absolute guarantee under scheduling pauses set `safety_margin: -1` and raise `ttl` / lower `loop_wait`+`retry_timeout` accordingly. Only tighten (sub-25 s failover) after proving DCS/network/PG latency fit the smaller windows under load.
5. **Test the watchdog before you trust it.** Use `soft_noboot=1` and the `driver: testing` harness for dry runs, then do a real `kill -9 patroni` on a primary and a `sysrq` panic to confirm both userspace-death and kernel-wedge recovery paths. Verify a replica promotes and the reset timing matches `ttl − safety_margin`.
6. **On Kubernetes, don't expect kernel-watchdog fencing.** Run Patroni `mode: off` (or automatic) and rely on the DCS lease + K8s; for CNPG, run **synchronous replication** and adopt 1.27+ for the isolation-aware liveness probe. Treat `keepalived`/VIP and repmgr/pg_auto_failover deployments as *not* having a hard fencing guarantee unless you add STONITH/SBD or a self-fence script.
7. **For shared-storage or non-Patroni stacks, use Pacemaker + SBD.** Diskless SBD (≥3 nodes or 2 + QDevice) gives Patroni-equivalent self-fencing; add disk-based SBD for a poison-pill on two-node clusters. Always a hardware watchdog for SBD in production.

## Caveats

- **softdog vs kernel wedge**: softdog relies on kernel timers and will *not* fire if the kernel is fully locked or (in a VM) while the hypervisor has the guest paused (the reset lands only after resume). ClusterLabs deems software watchdogs "unreliable for fencing purposes"; Patroni deems softdog "secure enough" for the process-death case. Both are correct for their respective threat models — use a hardware watchdog where you must cover kernel lockups.
- **`safety_margin` residual window**: even with the default margin, a Patroni suspension at exactly the wrong instant between lease-renewal and keepalive can theoretically slip past lease expiry; only `safety_margin: -1` (`ttl//2`) closes it fully.
- **Terminology**: "watchdog" means at least three different things across this ecosystem (kernel `/dev/watchdog`; kernel lockup detectors; pgpool-II's quorum/VIP subsystem). Ensure the reader's other Patroni document doesn't conflate them.
- **Version drift**: Patroni internals cited are from current `master`/4.x (`base.py`, `linux.py`, `ha.py`); field/method names (`_MemberStatus.watchdog_failed`, `update_lock`) have shifted across 2.x→4.x (e.g. `master`→`primary` role naming). CNPG isolation-probe behavior is 1.26 experimental / 1.27 default and evolving. Verify against the exact versions you run.
- Some cited configuration blogs (OneUptime, Stack Harbor, Medium) are secondary sources; the primary kernel/Patroni/ClusterLabs/pgpool docs and source code were used for all load-bearing claims.