# Turnkey install for the one-arm OpenWrt PoC

This ExecPlan is a living document. Update its progress, discoveries, decisions and outcome as the work proceeds.

## Purpose

Make the existing one-arm RouteCraft PoC installable on a clean, supported OpenWrt router with one short command from the public repository. The helper downloads the correct architecture bundle, installs required OpenWrt packages, prompts for site settings and secrets, validates the generated sing-box config, and only then asks for explicit activation. The same LAN interface remains the client-facing and upstream-facing interface; RouteCraft does not edit the router's LAN gateway distribution. A two-interface WAN/LAN design is explicitly out of scope for this stage.

Do not modify the live physical router or R28S as part of this plan. Implement and validate against the isolated RouteCraft VM(s). The installer must not run `apk upgrade` or `opkg upgrade`, remove unrelated services, or silently take over existing policy routing.

## Progress

- [x] (2026-11-13) Reviewed the current installer and confirmed that it only stages RouteCraft files and assumes sing-box/network dependencies are already present.
- [x] (2026-11-13) Confirmed from OpenWrt and sing-box upstream references that OpenWrt 25.12 uses APK, earlier releases use opkg, and the official full sing-box package can include `with_tailscale`; runtime preflight must still verify the endpoint.
- [x] (2026-11-13) Added targeted `apk`/`opkg` package installation, checking one-arm topology and conflicts first; verified package names and embedded Tailscale support through the OpenWrt 25.12.6 APK feeds.
- [x] (2026-11-13) Added a standalone public-repository bootstrap that selects the matching architecture bundle, verifies SHA256, stages the package, and starts the configuration wizard.
- [x] (2026-11-13) Added tag-triggered GitHub release automation for the three bundles and checksum files.
- [x] (2026-11-13) Validated package bootstrap, SHA256 on BusyBox, sing-box Tailscale feature, staging without activation, explicit activation/cancellation, and four real client routes on VM1/VM2; documented the results.
- [x] (2026-11-14) Replayed the user-facing local-bundle installation instructions on VM2 through candidate generation and decline-activation; confirmed modes, active service and route state.
- [x] (2026-11-13) Committed and pushed the completed one-arm turnkey stage to `origin/main`.

## Scope and design

The public bootstrap is the only file fetched directly from the repository branch. It downloads a versioned GitHub Release bundle by `uname -m`, verifies the published SHA256 sidecar, extracts to a temporary directory, then starts the packaged helper. `install.sh --install` detects `apk` or `opkg` and installs only required packages (`sing-box`, `curl`, `ca-bundle`, `ip-full`, `nftables-json`, and `kmod-nft-tproxy`) using the router's configured OpenWrt feeds. It must not modify feeds or upgrade the firmware. Package availability and the embedded Tailscale endpoint are checked before activation.

When RouteCraft itself installs sing-box, it disables the package's standalone procd service so only the RouteCraft service manages that process. It does not disable a pre-existing sing-box installation.

The package provides the existing one-arm TPROXY + same-interface SRCNAT behavior. It asks for or detects the single LAN interface and upstream values already supported by the PoC. It does not create WAN/LAN interface groups, modify UCI network topology, DHCP gateway options, or build a multi-zone router configuration.

## Validation

Run Go tests and create/hash all architecture bundles on the development host. On a disposable/isolated OpenWrt VM, begin with RouteCraft absent and required dependencies absent. Verify package installation uses `apk add` or `opkg install` only, confirms Tailscale and TPROXY support, stages the bundle, and preserves one-arm interface values. Test both declining activation and successful activation. From VM2, confirm Tailscale, VLESS, direct, and block test rules still behave as before. No live hardware is touched.

## Risks and recovery

Package installation needs working DNS/internet and valid stock OpenWrt feeds. Feed/package/kernel mismatch must stop installation with the package-manager error intact. A clean first trial has no RouteCraft config to roll back; package installation itself can remain after a later user cancels, while routes/service remain inactive. On non-clean routers, existing sing-box, nftables, mark, or table collisions block activation. The helper must preserve its current typed activation and backup behavior.

## Outcome

The source now has a one-command bootstrap path and tag-based release pipeline. On VM2 (OpenWrt 25.12.6 x86_64), `--install` installed missing `sing-box` and kernel TPROXY dependencies from configured APK feeds, confirmed the embedded Tailscale endpoint, disabled the package's standalone sing-box service, and staged RouteCraft without enabling its service or changing the default route. On VM1, the staged bundle activated successfully; VM2 then confirmed Tailscale, VLESS, direct and block behavior through the one-arm gateway. The GitHub Release itself is not published yet; it will be created by pushing a `v*` tag after the repository is public.

## Change note

Created on 2026-11-13 after the user clarified that the PoC install must be turnkey for a one-arm router. The two-interface WAN/LAN model is deferred to a later stage.
