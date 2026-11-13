# Build an OpenWrt install and configuration helper

This first installer phase is complete. Its initial assumption that runtime dependencies were preinstalled is superseded by `docs/turnkey-onearm-execplan.md`, which adds dependency installation and the public GitHub bootstrap for the one-arm PoC.

This ExecPlan is a living document. Maintain `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` as work proceeds, following the ExecPlan requirements in the local `execplans` skill.

## Purpose / Big Picture

The repository currently has a working gateway PoC and manual copy/paste setup instructions, but no installer or first-run configuration helper. This work produces a portable bundle that a user can copy to an OpenWrt router, inspect with a read-only preflight, configure with prompts, and explicitly install or activate. The original validation used dedicated VMs; a later user instruction authorized installation diagnosis and package staging on a user-managed OpenWrt router. R28S remains untouched and its exact OpenWrt build and CPU architecture are still unknown.

The first deliverable installs and starts the existing PoC; it does not claim that the incomplete general `routecraft apply` product command exists. The helper must protect an existing router configuration: default inspection is read-only, an incompatible listener or routing mark is reported before activation, secrets are prompted without echo and stored with mode 0600, and the user must explicitly confirm activation.

## Progress

- [x] (2026-11-13) Inspected repository: no installer exists; `poc/README.md` only documents manual assembly and start scripts.
- [x] (2026-11-13) Confirmed target notes: the primary physical target uses OpenWrt 25.12.6 x86_64 with a one-arm interface; R28S exact OpenWrt build and CPU architecture are not yet documented.
- [x] (2026-11-13) Implemented cross-build bundles and SHA256 sidecars for x86_64, ARM64, and ARMv7.
- [x] (2026-11-13) Implemented target-side read-only preflight, staged install, prompted configuration, safe secret files, candidate generation, and explicit activation.
- [x] (2026-11-13) Validated shell syntax, read-only preflight, staged install without changing active JSON/process, candidate generation on a cached subscription fixture, explicit activation, and four real client routes on the isolated RouteCraft VM.
- [x] (2026-11-13) Rebuilt all architecture bundles, verified SHA256 sidecars, and committed/pushed the installer and documentation to `origin/main`.
- [x] (2026-11-14) After explicit user authorization, diagnosed and prepared a user-managed OpenWrt router: restored its internet access, installed runtime packages from OpenWrt feeds, reran preflight successfully, and left RouteCraft inactive. At that stage the first Release had not yet been published; the later repository-only install path no longer depends on one.
- [x] (2026-11-14) After the user clarified that installation must not depend on a Release, moved the architecture bundles into tracked `poc/bundles/`, changed bootstrap downloads to raw `main` assets, and updated the install guide. Verify the pushed URLs and package-builder output before marking this correction complete.

## Surprises & Discoveries

- Observation: a persistent procd service and PoC configuration already exist, but only as hand-installed VM-specific files; there is no repository installer or package build target.

  Evidence: `poc/README.md` instructs manual `scp`, `chmod`, and `start.sh`; the repository has no `packaging/`, installer script, or `package-openwrt` make target.
- Observation: the test PoC uses fixed TPROXY mark/table/listener values. Reusing them on an existing router may collide with its own sing-box or firewall setup.

  Evidence: `poc/tproxy-gateway.sh` uses mark `0x81`, table `100`, and port `12345`; the primary target's handoff describes an existing TPROXY setup. Preflight must detect conflicts and refuse activation rather than replace unknown rules.
- Observation: the primary physical target has a documented x86_64/OpenWrt profile; R28S does not yet have a verified target architecture/build in repository documentation.

  Evidence: the handoff identifies the primary target as OpenWrt 25.12.6 x86_64 and lists other hardware as a later port, without R28S details. Build a few common Go targets and require runtime architecture detection; never assume R28S is ARM64.
- Observation: `sing-box version` on OpenWrt 25.12.6 prints only the version, not Go build tags; embedded Tailscale support can be tested with `sing-box check` on a temporary config.

  Evidence: version output was `sing-box version 1.13.21`; a minimal `type: tailscale` endpoint config passed `sing-box check`.
- Observation: opening the config helper revealed an unexpanded `$interface` in the quoted nft heredoc. This would have caused the TPROXY chain to return for all traffic.

  Evidence: the active VM table initially displayed `iifname != "$interface" return`; after changing the heredoc and reloading the owned table it displayed `iifname != "br-lan" return`, TPROXY counter increased, and all four client routes passed.
- Observation: the subscription provider returned HTTP 502 during one wizard test; the last saved test snapshot worked as a local fixture and candidate validation completed.

  Evidence: live fetch returned curl HTTP 502; with the same saved subscription exposed through temporary uhttpd, the helper generated a 12,595-byte candidate and `sing-box check` succeeded. The active config hash remained unchanged.
- Observation: the target router initially could not reach the internet, so its bootstrap request failed even though it could reach a local neighbor.

  Evidence: after internet access was restored on the router, `uclient-fetch -4` downloaded the source bootstrap with HTTP 200.

## Decision Log

- Decision: package the existing PoC first, not the incomplete production `apply` subsystem.

  Rationale: the user wants a usable install/configuration helper to try at two sites; the current PoC already routes traffic and has real egress evidence, while general transactional apply is not implemented. Keep the claim and scope explicit.

  Date/Author: 2026-11-13, Codex.

- Decision: prepare the router only as needed to restore internet access, install dependencies, and stop before RouteCraft activation.

  Rationale: the user explicitly authorized direct diagnosis; the router had no internet access. Restoring ordinary internet access allowed the installer to be tested without redirecting client traffic through new RouteCraft rules.

  Date/Author: 2026-11-14, Codex.
- Decision: the bundle builder will include Linux `amd64`, `arm64`, and `arm`/GOARM=7 variants; the target helper selects only by `uname -m` and refuses an unknown architecture.

  Rationale: x86_64 is documented for the primary physical target and the R28S architecture is unknown. A small set of common binaries allows later testing without claiming universal OpenWrt compatibility.

  Date/Author: 2026-11-13, Codex.
- Decision: preflight is read-only and activation is a separate explicit choice. The helper will not stop an unrecognized sing-box, delete unknown nftables tables, or rewrite the LAN gateway.

  Rationale: the primary physical target is a live one-arm router with a pre-existing setup; silent takeover could disconnect users. The installer requires explicit activation on live targets.

  Date/Author: 2026-11-13, Codex.
- Decision: expose the LAN interface, subnet and DNS upstream to the PoC scripts/builder instead of retaining the VM-only `br-lan`/`.254` defaults.

  Rationale: the same setup helper should adapt to a one-arm LAN and a later R28S LAN without adding another network-management daemon. Values are detected from UCI/routes and can be corrected in the interactive prompts.

  Date/Author: 2026-11-13, Codex.

## Outcomes & Retrospective

Implemented a cross-platform OpenWrt PoC bundle and guarded installer/configuration flow. On VM1, `install.sh --check` passed; `--install` staged the package while preserving the active sing-box JSON hash and process id; a wizard candidate built from the saved subscription fixture passed `sing-box check`, and secrets had mode 0600. Activation then started the procd service and VM2 again returned the expected Tailscale, VLESS, direct, and reject outcomes. The first activation test caught and fixed an unexpanded interface variable before its final traffic check.

The VLESS provider briefly returned HTTP 502, so new configuration could not be sourced from it during the VM test; the helper failed safely, then the flow was validated using a local fixture of the last saved test subscription. A later, user-authorized run on a live OpenWrt router restored internet access, installed `sing-box 1.13.21` and required packages, and passed the second preflight with 23.6 MiB free. RouteCraft service/rules were not activated. The current helper is still for the PoC, not the future transactional production `apply` command. Prebuilt architecture bundles are now committed in `poc/bundles/`, so installation from public `main` does not depend on any GitHub Release. R28S remains untouched; collect its OpenWrt release and `uname -m` before choosing its bundle.

## Context and Orientation

The repository root is `D:/Projects/github.com/vasiliy82/routecraft`. `poc/build/main.go` reads the PoC YAML and VLESS subscription and creates a sing-box JSON file. `poc/policy.yaml` declares first-match routes. `poc/start.sh` currently downloads SRS and a subscription, generates the config, starts sing-box, and applies gateway nftables scripts. `poc/direct-gateway.sh` enables IPv4 forwarding/SNAT; `poc/tproxy-gateway.sh` installs policy routing and catches transit TCP/UDP; `poc/routecraft-poc.init` restores the saved setup via OpenWrt procd. The dedicated gateway and client are documented in the private test journal. A later user instruction authorized diagnosis on the live router; RouteCraft itself was not activated there.

An install bundle is a compressed file containing the target-specific PoC builder and scripts. `amd64`, `arm64`, and `armv7` are CPU instruction targets used by Go; OpenWrt package architecture strings can differ, so the helper inspects `uname -m` rather than trusting a package-manager label. A preflight reports current state and does not change the router. Activation means starting the RouteCraft PoC so its nftables rules and sing-box process begin handling clients.

The current package does not manage arbitrary production configs. Existing tables, policy rules, listeners, and services remain owned by their existing programs. The helper must detect obvious collisions with TCP/UDP port `12345`, mark `0x81`/table `100`, and RouteCraft table names. If state is ambiguous, preparation is allowed but activation is refused with a readable diagnostic; the user decides a migration separately.

## Plan of Work

First add a PowerShell bundle builder under `scripts/` and a `make package-openwrt` entry. It cross-compiles the existing `poc/build` command for x86_64, ARM64, and ARMv7 without cgo, packages the scripts, policy template and target binaries, and writes a SHA256 manifest. The package must not contain a production secret. The default policy remains a template and secrets are collected only on the target.

Next add a POSIX `ash` install/preflight script and an interactive configuration script in `poc/`. Preflight checks root permissions, OpenWrt release, `uname -m`, free persistent space, `sing-box` version/build features, `curl`, `ip`, `nft`, TPROXY support, LAN interface/subnet, upstream gateway, active listeners, and conflicting nft/IP rules. `--check` is read-only. Configuration detects reasonable defaults from UCI, allows explicit edits, asks for subscription URL and Headscale key with terminal echo disabled, and stores sensitive files with owner-only permissions. It does not change the client's default gateway.

The installer stages files under `/etc/routecraft-poc`, preserves an existing directory in a timestamped backup, verifies the selected binary, generates a candidate config, and runs `sing-box check`. It must not activate while unrelated TPROXY ownership is detected. If checks are clean, it shows the exact network changes and waits for an explicit typed confirmation before installing/enabling the procd service. Repeated install must keep one service, one policy rule, one owned nft table, and preserve the previous candidate if generation fails.

Finally run unit tests and bundle builds on the development host, then test `--check`, install, service start, repeated install, and real client traffic on dedicated VMs. Record observed output in `docs/development-journal.md`, update `poc/README.md` with the copy/paste user workflow, and link the new helper from the root README. Keep a short target checklist for the primary physical router and R28S, including how to gather `cat /etc/openwrt_release`, `uname -m`, `df -h / /tmp`, `sing-box version`, and current route/table/listener state before activation.

## Concrete Steps

From PowerShell at the repository root, build the bundles and per-archive checksum sidecars with:

    make package-openwrt

It produces one bundle and matching `.sha256` sidecar per supported architecture under `poc/bundles/`. These are tracked distribution files, so after checking the hashes, commit the updated bundles alongside the source. The public bootstrap selects the matching archive from this directory directly.

    sh ./install.sh --check

Expected behavior is a concise detected platform/dependency/conflict report and no change to files, routes, firewall, or running processes. Interactive setup and activation commands will be finalized alongside their implementation and recorded here.

On the isolated VM, positive acceptance requires the same HTTP 200 / routed-IP results already obtained by the PoC for `2ip.io`, `ifconfig.me`, `icanhazip.com`, plus a reset for `theuselessweb.com`, all with sing-box route evidence. For physical targets, this plan creates instructions and bundles; activation requires explicit user action.

## Validation and Acceptance

`go test ./...` must pass. The bundle builder must create each named architecture and verify its manifest against the produced files. Shell syntax checks must pass using the available OpenWrt `ash` on a VM. A read-only preflight must leave a before/after snapshot of relevant config, routes, nft rules, and processes identical. A staged install and a repeated install must be idempotent. Activation must be refused for an injected port/mark conflict without stopping the existing test service. In a clean disposable VM fixture, activation must start procd and route client requests through the four expected outcomes; stop must remove only RouteCraft-owned rules.

Do not call the helper production-ready merely because files copy or sing-box starts. It is ready for the user's first manual trial when the VM evidence, clear conflict behavior, package checksums, target instructions, and known limits are recorded. Physical target functionality remains unverified until separately tested.

## Idempotence and Recovery

`--check` must be safe to repeat and strictly read-only. Installation never overwrites a previous config silently: first save it to `/root/routecraft-backup-<timestamp>` and preserve mode/ownership; config generation happens in a candidate directory and is promoted only after successful parsing and `sing-box check`. Any pre-activation failure leaves the current service untouched. Activation is explicit. The installer does not alter `/etc/config/network`, LAN gateway distribution, DNS advertisement, user routes outside its own mark/table, unrelated nftables chains, or unrecognized sing-box processes. The user can restore the saved `/etc/routecraft-poc` snapshot and restart its previous service; use this recovery carefully on user-managed routers.

## Artifacts and Notes

Current evidence from the dedicated PoC: VM2 reaches `2ip.io` through Tailscale, `ifconfig.me` through VLESS, `icanhazip.com` direct, and `theuselessweb.com` is rejected. The user-managed OpenWrt router has staged runtime packages, but RouteCraft remains inactive. R28S is outside this plan's write scope.

## Interfaces and Dependencies

The host package builder uses Go's standard `go build` cross-compilation and PowerShell/Windows `tar` plus `certutil` or PowerShell SHA256. The router helper uses only `/bin/sh`/BusyBox ash and existing OpenWrt tools; it does not require local Python. Runtime requirements are the tested sing-box build with `with_tailscale`, `curl`, `ip-full`, nftables TPROXY support, and enough persistent space. Since package names/repositories vary by OpenWrt release, first version reports missing dependencies instead of silently installing an unverified package.

Change note: created on 2026-11-13 after the user asked for an installer/configuration helper for a physical OpenWrt target, then R28S. Update on 2026-11-13 records implementation and VM testing of architecture bundles, preflight, staged install, prompted configuration and explicit activation; a TPROXY heredoc defect found during activation was corrected before acceptance. The 2026-11-14 user-authorized router connectivity repair and dependency installation are recorded above; RouteCraft was not activated.

## Update 2026-11-14 — user-authorized router installation diagnosis

The earlier restriction against touching the live router is superseded by the user's explicit authorization in this task. The purpose was to diagnose the reported bootstrap download error and test installation directly on an OpenWrt host. The router initially had no working internet connection. After connectivity was restored, the amd64 package passed its SHA256 check and its runtime dependencies were installed.

The amd64 package built from this working tree passed its SHA256 check. `install.sh --install` installed `sing-box 1.13.21`, `curl`, `ip-full`, `kmod-nf-tproxy`, and `kmod-nft-tproxy`; a second `install.sh --check` passed including the TPROXY kernel expression and embedded Tailscale endpoint check. No RouteCraft service was started, and no RouteCraft routes, tables, or nftables rules were activated. Initially the online bootstrap depended on a tagged Release; the user clarified that installation must work directly from the public repository branch, so bundles are now tracked in `poc/bundles/` and the bootstrap downloads those raw files. Detailed test output is kept in `docs/development-journal.md`.

## Update 2026-11-14 — first release and OpenWrt download path

The user clarified that a GitHub Release must not be required for installation. The architecture bundles are now stored directly in `poc/bundles/` on `main`, and `poc/install-openwrt.sh` downloads them and their SHA256 sidecars from `raw.githubusercontent.com`. The bundle builder writes to this tracked directory; staging stays under ignored `.cache/`. Tagged Releases may remain an optional distribution format, but are not part of the clean-router installation path. The initial tracked bundles came from a previously verified build, with all sidecar hashes checked before copying. The direct raw download and SHA256 check from OpenWrt remain the next acceptance check after pushing these changes.
