// Command build creates the single sing-box configuration used by the PoC.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/vasiliy82/routecraft/internal/compiler"
	"github.com/vasiliy82/routecraft/internal/dnsprobe"
	"github.com/vasiliy82/routecraft/internal/netdevices"
	"github.com/vasiliy82/routecraft/internal/openwrt"
	"github.com/vasiliy82/routecraft/internal/policy"
	"github.com/vasiliy82/routecraft/internal/routinginspect"
	"github.com/vasiliy82/routecraft/internal/tailscalestatus"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func main() {
	settingsPath := flag.String("policy", "/tmp/routecraft/policy.yaml", "policy YAML")
	subscriptionPath := flag.String("subscription", "/tmp/routecraft/subscription.raw", "downloaded subscription")
	keyPath := flag.String("headscale-key", "/tmp/routecraft/headscale.key", "Tailscale or Headscale auth key")
	dataDir := flag.String("data", "/tmp/routecraft", "rule-set and state directory")
	control := flag.String("headscale", "https://controlplane.tailscale.com", "Tailscale or Headscale URL")
	exitNode := flag.String("exit-node", "", "Tailscale exit node")
	dnsUpstream := flag.String("dns", "", "DNS upstream reachable from the gateway")
	output := flag.String("output", "/tmp/routecraft/sing-box.json", "generated sing-box configuration")
	omitInitial := flag.Bool("omit-unavailable-initial-vpn", false, "omit unavailable VPN rules from initial policy")
	checkSubscription := flag.Bool("check-subscription", false, "validate a downloaded VLESS subscription without building a configuration")
	listInterfaces := flag.Bool("list-interfaces", false, "list selectable Linux network devices")
	checkInterface := flag.String("check-interface", "", "check whether a Linux network device is selectable")
	exitNodes := flag.String("list-exit-nodes", "", "read local Tailscale status JSON and list online approved exit nodes")
	checkExitNode := flag.String("check-exit-node", "", "validate an address against the supplied Tailscale status")
	networkStatus := flag.String("network-status", "", "read OpenWrt network.interface dump from file")
	interfaceDevice := flag.String("interface-device", "", "find logical interfaces for a network device")
	dhcpStatus := flag.String("dhcp-status", "", "read UCI DHCP status JSON from file")
	logicalInterface := flag.String("logical-interface", "", "find DHCP sections for a logical interface")
	poolPrefix := flag.String("pool-prefix", "", "IPv4 LAN prefix for DHCP pool validation")
	poolRouter := flag.String("pool-router", "", "router IPv4 address for DHCP pool validation")
	poolStart := flag.Uint64("pool-start", 0, "DHCP pool starting offset")
	poolSize := flag.Uint64("pool-size", 0, "number of DHCP pool addresses")
	dhcpPlan := flag.String("dhcp-plan", "", "read JSON input and prepare a DHCP change plan without applying it")
	uciPlan := flag.String("uci-dhcp-plan", "", "read a DHCP plan and prepare a scoped UCI request")
	uciSection := flag.String("uci-section", "", "target UCI DHCP section")
	uciSession := flag.String("uci-session-file", "", "file containing the scoped UCI session ID")
	verifyPlan := flag.String("verify-dhcp-plan", "", "compare a restored UCI section with its saved snapshot")
	uciBefore := flag.String("uci-before", "", "saved UCI section snapshot")
	uciCurrent := flag.String("uci-current", "", "current UCI section snapshot")
	checkDNS := flag.String("check-dns", "", "check an IP DNS listener over UDP and TCP")
	dnsProbeName := flag.String("dns-probe-name", "example.com.", "absolute name for the DNS listener check")
	dnsStatus := flag.String("dns-status", "", "inspect dnsmasq instances in a UCI status file")
	dnsPlan := flag.String("dns-plan", "", "prepare a DNS binding plan from JSON input")
	uciDNSPlan := flag.String("uci-dns-plan", "", "prepare a scoped UCI DNS request")
	verifyDNSPlan := flag.String("verify-dns-plan", "", "compare DNS settings to a UCI snapshot")
	routingRules := flag.String("check-routing-rules", "", "check JSON policy rules for reserved mark/table conflicts")
	routingRoutes := flag.String("check-routing-routes", "", "check JSON routes in the reserved policy table")
	ownedLAN := flag.String("owned-lan", "", "allow one exact existing RouteCraft rule on this LAN")
	flag.Parse()
	if *routingRoutes != "" {
		data, err := os.ReadFile(*routingRoutes)
		if err == nil {
			err = routinginspect.CheckRoutes(data, 100, *ownedLAN != "")
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: IPv4 routes:", err)
			os.Exit(1)
		}
		return
	}
	if *routingRules != "" {
		data, err := os.ReadFile(*routingRules)
		if err == nil {
			if *ownedLAN == "" {
				err = routinginspect.Check(data, 0x81, 100)
			} else {
				err = routinginspect.CheckOwned(data, 0x81, 100, *ownedLAN)
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: IPv4 policy rules:", err)
			os.Exit(1)
		}
		return
	}
	if *dnsPlan != "" {
		data, err := os.ReadFile(*dnsPlan)
		var request struct {
			Instances      []openwrt.DNSInstance `json:"instances"`
			Logical        string                `json:"logical"`
			Device         string                `json:"device"`
			IPv4           string                `json:"ipv4"`
			IPv6           string                `json:"ipv6"`
			NoPortConflict bool                  `json:"no_port_conflict"`
		}
		if err == nil {
			decoder := json.NewDecoder(bytes.NewReader(data))
			decoder.DisallowUnknownFields()
			err = decoder.Decode(&request)
		}
		var ipv4, ipv6 netip.Addr
		if err == nil {
			ipv4, err = netip.ParseAddr(request.IPv4)
		}
		if err == nil {
			ipv6, err = netip.ParseAddr(request.IPv6)
		}
		if err == nil {
			var plan openwrt.DNSPlan
			plan, err = openwrt.PlanDNS(request.Instances, request.Logical, request.Device, ipv4, ipv6, request.NoPortConflict)
			if err == nil {
				err = json.NewEncoder(os.Stdout).Encode(plan)
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: cannot prepare DNS plan:", err)
			os.Exit(1)
		}
		return
	}
	if *uciDNSPlan != "" || *verifyDNSPlan != "" {
		if *uciDNSPlan != "" && *verifyDNSPlan != "" {
			fmt.Fprintln(os.Stderr, "routecraft: choose one DNS UCI operation")
			os.Exit(1)
		}
		path := *uciDNSPlan
		if *verifyDNSPlan != "" {
			path = *verifyDNSPlan
		}
		data, err := os.ReadFile(path)
		var plan openwrt.DNSPlan
		if err == nil {
			err = json.Unmarshal(data, &plan)
		}
		if err == nil && *verifyDNSPlan != "" {
			var before, current []byte
			before, err = os.ReadFile(*uciBefore)
			if err == nil {
				current, err = os.ReadFile(*uciCurrent)
			}
			if err == nil {
				err = openwrt.VerifyDNSRestored(plan, before, current)
			}
			if err == nil {
				fmt.Println("Touched DNS options match the saved snapshot.")
			}
		} else if err == nil {
			var session []byte
			session, err = os.ReadFile(*uciSession)
			if err == nil {
				var payload []byte
				payload, err = openwrt.DNSUCIRequest(plan, strings.TrimSpace(string(session)))
				if err == nil {
					_, err = os.Stdout.Write(append(payload, '\n'))
				}
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: cannot process DNS UCI plan:", err)
			os.Exit(1)
		}
		return
	}
	if *dnsStatus != "" {
		data, err := os.ReadFile(*dnsStatus)
		if err == nil {
			var instances []openwrt.DNSInstance
			instances, err = openwrt.DNSInstances(data)
			if err == nil {
				err = json.NewEncoder(os.Stdout).Encode(instances)
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: cannot inspect dnsmasq instances")
			os.Exit(1)
		}
		return
	}
	if *checkDNS != "" {
		endpoint, err := netip.ParseAddrPort(*checkDNS)
		if err != nil {
			var addr netip.Addr
			addr, err = netip.ParseAddr(*checkDNS)
			endpoint = netip.AddrPortFrom(addr, 53)
		}
		if err != nil || endpoint.Port() == 0 || endpoint.Addr().IsUnspecified() || endpoint.Addr().IsMulticast() {
			fmt.Fprintln(os.Stderr, "routecraft: invalid DNS listener address")
			os.Exit(1)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := dnsprobe.Check(ctx, endpoint.String(), *dnsProbeName); err != nil {
			fmt.Fprintln(os.Stderr, "routecraft:", err)
			os.Exit(1)
		}
		fmt.Println("DNS listener answered over UDP and TCP.")
		return
	}
	if *verifyPlan != "" || *uciBefore != "" || *uciCurrent != "" {
		if *verifyPlan == "" || *uciBefore == "" || *uciCurrent == "" {
			fmt.Fprintln(os.Stderr, "routecraft: plan and both UCI snapshots are required")
			os.Exit(1)
		}
		data, err := os.ReadFile(*verifyPlan)
		var plan openwrt.DHCPPlan
		if err == nil {
			err = json.Unmarshal(data, &plan)
		}
		var before, current []byte
		if err == nil {
			before, err = os.ReadFile(*uciBefore)
		}
		if err == nil {
			current, err = os.ReadFile(*uciCurrent)
		}
		if err == nil {
			err = openwrt.VerifyDHCPRestored(plan, before, current)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: DHCP restoration not confirmed:", err)
			os.Exit(1)
		}
		fmt.Println("Touched DHCP options match the saved snapshot.")
		return
	}
	if *uciPlan != "" || *uciSection != "" || *uciSession != "" {
		if *uciPlan == "" || *uciSection == "" || *uciSession == "" {
			fmt.Fprintln(os.Stderr, "routecraft: UCI plan, section and session are required")
			os.Exit(1)
		}
		data, err := os.ReadFile(*uciPlan)
		var plan openwrt.DHCPPlan
		if err == nil {
			err = json.Unmarshal(data, &plan)
		}
		var session []byte
		if err == nil {
			session, err = os.ReadFile(*uciSession)
		}
		if err == nil {
			var payload []byte
			payload, err = openwrt.DHCPUCIRequest(plan, *uciSection, strings.TrimSpace(string(session)))
			if err == nil {
				_, err = os.Stdout.Write(append(payload, '\n'))
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: cannot prepare UCI request:", err)
			os.Exit(1)
		}
		return
	}
	if *dhcpPlan != "" {
		data, err := os.ReadFile(*dhcpPlan)
		var request struct {
			Mode        string   `json:"mode"`
			RA          string   `json:"ra"`
			Backend     string   `json:"backend"`
			Prefix      string   `json:"prefix"`
			Router      string   `json:"router"`
			DNS6        string   `json:"dns6"`
			Start       uint32   `json:"start"`
			Limit       uint32   `json:"limit"`
			DHCPOptions []string `json:"dhcp_options"`
		}
		if err == nil {
			decoder := json.NewDecoder(bytes.NewReader(data))
			decoder.DisallowUnknownFields()
			err = decoder.Decode(&request)
			if err == nil {
				var extra any
				if e := decoder.Decode(&extra); e != io.EOF {
					err = fmt.Errorf("multiple JSON values are not supported")
				}
			}
		}
		var pool openwrt.IPv4Pool
		var dns6 netip.Addr
		if err == nil && request.Mode == "managed" {
			pool.Prefix, err = netip.ParsePrefix(request.Prefix)
			if err == nil {
				pool.Router, err = netip.ParseAddr(request.Router)
			}
			if err == nil {
				dns6, err = netip.ParseAddr(request.DNS6)
			}
			pool.Start, pool.Limit = request.Start, request.Limit
		}
		if err == nil {
			var plan openwrt.DHCPPlan
			plan, err = openwrt.PlanDHCP(request.Mode, request.RA, request.Backend, pool, dns6, request.DHCPOptions)
			if err == nil {
				err = json.NewEncoder(os.Stdout).Encode(plan)
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: cannot prepare DHCP plan:", err)
			os.Exit(1)
		}
		return
	}
	if *poolPrefix != "" || *poolRouter != "" || *poolStart != 0 || *poolSize != 0 {
		prefix, prefixErr := netip.ParsePrefix(*poolPrefix)
		router, routerErr := netip.ParseAddr(*poolRouter)
		if prefixErr != nil || routerErr != nil || *poolStart > 1<<32-1 || *poolSize > 1<<32-1 {
			fmt.Fprintln(os.Stderr, "routecraft: invalid DHCP pool input")
			os.Exit(1)
		}
		pool := openwrt.IPv4Pool{Prefix: prefix, Router: router, Start: uint32(*poolStart), Limit: uint32(*poolSize)}
		if err := pool.Validate(); err != nil {
			fmt.Fprintln(os.Stderr, "routecraft:", err)
			os.Exit(1)
		}
		fmt.Println("DHCP pool is valid.")
		return
	}
	if *dhcpStatus != "" || *logicalInterface != "" {
		if *dhcpStatus == "" || *logicalInterface == "" {
			fmt.Fprintln(os.Stderr, "routecraft: DHCP status and logical interface are required")
			os.Exit(1)
		}
		data, err := os.ReadFile(*dhcpStatus)
		if err == nil {
			var sections []openwrt.DHCPSection
			sections, err = openwrt.DHCPSections(data, *logicalInterface)
			if err == nil {
				err = json.NewEncoder(os.Stdout).Encode(sections)
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: cannot inspect DHCP sections")
			os.Exit(1)
		}
		return
	}
	if *networkStatus != "" || *interfaceDevice != "" {
		if *networkStatus == "" || *interfaceDevice == "" {
			fmt.Fprintln(os.Stderr, "routecraft: network status and device are required")
			os.Exit(1)
		}
		data, err := os.ReadFile(*networkStatus)
		if err == nil {
			var interfaces []openwrt.LogicalInterface
			interfaces, err = openwrt.InterfacesForDevice(data, *interfaceDevice)
			if err == nil {
				err = json.NewEncoder(os.Stdout).Encode(interfaces)
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: cannot inspect OpenWrt interfaces")
			os.Exit(1)
		}
		return
	}
	if *checkExitNode != "" && *exitNodes == "" {
		fmt.Fprintln(os.Stderr, "routecraft: Tailscale status file is required")
		os.Exit(1)
	}
	if *exitNodes != "" {
		data, err := os.ReadFile(*exitNodes)
		if err == nil {
			if *checkExitNode != "" {
				var node tailscalestatus.Candidate
				node, err = tailscalestatus.Select(data, *checkExitNode)
				if err == nil {
					err = json.NewEncoder(os.Stdout).Encode(node)
				}
			} else {
				var nodes []tailscalestatus.Candidate
				nodes, err = tailscalestatus.Candidates(data)
				if err == nil {
					err = json.NewEncoder(os.Stdout).Encode(nodes)
				}
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: cannot inspect Tailscale status")
			os.Exit(1)
		}
		return
	}
	if *listInterfaces || *checkInterface != "" {
		devices, err := netdevices.ListWithVLAN("/sys/class/net", "/proc/net/vlan")
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft:", err)
			os.Exit(1)
		}
		for _, device := range devices {
			if *checkInterface == device {
				return
			}
			if *listInterfaces {
				fmt.Println(device)
			}
		}
		if *checkInterface != "" {
			fmt.Fprintln(os.Stderr, "routecraft: interface is not selectable")
			os.Exit(1)
		}
		return
	}
	if *checkSubscription {
		data, err := os.ReadFile(*subscriptionPath)
		if err == nil {
			_, _, err = parseSubscription(data)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "routecraft: invalid VLESS subscription")
			os.Exit(1)
		}
		fmt.Println("VLESS subscription contains supported nodes.")
		return
	}
	if err := build(*settingsPath, *subscriptionPath, *keyPath, *dataDir, *control, *exitNode, *dnsUpstream, *output, *omitInitial); err != nil {
		fmt.Fprintln(os.Stderr, "routecraft:", err)
		os.Exit(1)
	}
}

func build(settingsPath, subscriptionPath, keyPath, dataDir, control, exitNode, dnsUpstream, output string, omitInitial bool) error {
	if strings.TrimSpace(dnsUpstream) == "" {
		return fmt.Errorf("DNS upstream is required")
	}
	data, err := os.ReadFile(settingsPath)
	if err != nil {
		return err
	}
	p, err := policy.Parse(data)
	if err != nil {
		return err
	}
	if p.Version == 0 {
		p.Version = 1
	}
	for i := range p.Rules {
		switch p.Rules[i].Outbound {
		case "через конкретную tailscale exit node":
			p.Rules[i].Outbound = "tailscale-exit"
		case "через VPN subscription":
			p.Rules[i].Outbound = "vpn-sub"
		}
	}
	var nodes []map[string]any
	var tags []string
	if subscriptionPath != "" {
		sub, err := os.ReadFile(subscriptionPath)
		if err != nil {
			return err
		}
		nodes, tags, err = parseSubscription(sub)
		if err != nil {
			return err
		}
	}
	var key []byte
	if exitNode != "" {
		if control == "" || keyPath == "" {
			return fmt.Errorf("control URL and key are required for Tailscale")
		}
		key, err = os.ReadFile(keyPath)
		if err != nil {
			return err
		}
		if strings.TrimSpace(string(key)) == "" {
			return fmt.Errorf("Headscale key is empty")
		}
	}
	if err := omitUnavailable(&p, len(nodes) > 0, len(key) > 0, omitInitial); err != nil {
		return err
	}
	if _, ok := p.DNS["vpn-sub"]; ok && len(nodes) == 0 {
		return fmt.Errorf("DNS profile requires unavailable outbound vpn-sub")
	}
	if _, ok := p.DNS["tailscale-exit"]; ok && len(key) == 0 {
		return fmt.Errorf("DNS profile requires unavailable outbound tailscale-exit")
	}
	categories := policy.Categories{Version: 1, Categories: map[string]string{}}
	for _, rule := range p.Rules {
		for _, raw := range rule.Filter {
			kind, name, err := policy.SplitFilter(raw)
			if err != nil {
				return err
			}
			if kind == "geosite" || kind == "geoip" {
				path := filepath.Join(dataDir, kind, name+".srs")
				if _, err = os.Stat(path); err != nil {
					return fmt.Errorf("missing %s: %w", raw, err)
				}
				categories.Categories[kind+":"+name] = path
			}
		}
	}
	outbounds := policy.Outbounds{Version: 1, Outbounds: map[string]policy.Outbound{
		"direct":         {Type: "direct"},
		"reject":         {Type: "reject"},
		"vpn-sub":        {Type: "sing-box-tag", Tag: "vpn-sub"},
		"tailscale-exit": {Type: "sing-box-tag", Tag: "tailscale-exit"},
	}}
	compiled, err := compiler.Compile(compiler.Input{Policy: p, Outbounds: outbounds, Categories: categories})
	if err != nil {
		return err
	}
	compiled.Outbounds = append(compiled.Outbounds, nodes...)
	if len(nodes) > 0 {
		compiled.Outbounds = append(compiled.Outbounds, map[string]any{
			"type": "urltest", "tag": "vpn-sub", "outbounds": tags,
			"url": "https://www.gstatic.com/generate_204", "interval": "5m", "tolerance": 100,
		})
	}
	// Diagnostic listeners exercise each transport without changing the system route.
	rules := []map[string]any{{"inbound": []string{"test-direct"}, "action": "route", "outbound": "direct"}}
	inbounds := []any{
		map[string]any{"type": "tproxy", "tag": "gateway", "listen": "0.0.0.0", "listen_port": 12345},
		map[string]any{"type": "mixed", "tag": "test-direct", "listen": "127.0.0.1", "listen_port": 1080},
	}
	if len(nodes) > 0 {
		rules = append(rules, map[string]any{"inbound": []string{"test-vless"}, "action": "route", "outbound": "vpn-sub"})
		inbounds = append(inbounds, map[string]any{"type": "mixed", "tag": "test-vless", "listen": "127.0.0.1", "listen_port": 1081})
	}
	if len(key) > 0 {
		rules = append(rules, map[string]any{"inbound": []string{"test-exit"}, "action": "route", "outbound": "tailscale-exit"})
		inbounds = append(inbounds, map[string]any{"type": "mixed", "tag": "test-exit", "listen": "127.0.0.1", "listen_port": 1082})
	}
	// Bootstrap resolves transport endpoints independently from client DNS rules.
	bootstrap := map[string]any{"type": "udp", "tag": "local-dns", "server": dnsUpstream}
	var dns any = map[string]any{"servers": []any{bootstrap}, "final": "local-dns", "reverse_mapping": true}
	if compiled.DNS != nil {
		addr, err := netip.ParseAddr(dnsUpstream)
		if err != nil || addr.IsLoopback() || addr.IsUnspecified() || addr.IsMulticast() || addr.Zone() != "" {
			return fmt.Errorf("Split DNS bootstrap requires a separate unicast DNS server IP")
		}
		compiled.DNS.Servers = append(compiled.DNS.Servers, bootstrap)
		const healthName = "routecraft-health.example.com"
		compiled.DNS.Rules = append([]map[string]any{
			{"domain": []string{healthName}, "query_type": []string{"A"}, "action": "predefined", "answer": []string{healthName + ". 0 IN A 192.0.2.1"}},
			{"domain": []string{healthName}, "query_type": []string{"TXT"}, "action": "predefined", "answer": []string{healthName + `. 0 IN TXT "routecraft-dns-ready"`}},
		}, compiled.DNS.Rules...)
		dns = compiled.DNS
		inbounds = append(inbounds, map[string]any{"type": "direct", "tag": "routecraft-dns", "listen": "127.0.0.1", "listen_port": 10553})
		rules = append(rules, map[string]any{"inbound": []string{"routecraft-dns"}, "action": "hijack-dns"})
	}
	rules = append(rules, compiled.Route.Rules...)
	config := map[string]any{
		"log":       map[string]any{"level": "debug"},
		"dns":       dns,
		"inbounds":  inbounds,
		"outbounds": compiled.Outbounds,
		"route":     map[string]any{"rules": rules, "rule_set": compiled.Route.RuleSet, "final": compiled.Route.Final, "default_domain_resolver": "local-dns"},
	}
	if len(key) > 0 {
		stateDir := os.Getenv("ROUTECRAFT_TAILSCALE_STATE_DIR")
		if stateDir == "" {
			stateDir = filepath.Join(dataDir, "tailscale-state")
		}
		config["endpoints"] = []any{map[string]any{
			"type": "tailscale", "tag": "tailscale-exit", "state_directory": stateDir,
			"hostname": "routecraft", "control_url": control, "auth_key": strings.TrimSpace(string(key)),
			"exit_node": exitNode, "accept_routes": false, "exit_node_allow_lan_access": true, "system_interface": false,
		}}
	}
	encoded, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}
	if err = os.WriteFile(output, append(encoded, '\n'), 0o600); err != nil {
		return err
	}
	fmt.Printf("Generated PoC configuration with %d VLESS nodes and %d categories.\n", len(nodes), len(categories.Categories))
	return nil
}

// Omission is deliberately opt-in and limited to the two named initial rules.
// A custom rule or a default pointing to an unavailable VPN always fails.
func omitUnavailable(p *policy.Policy, vless, tailscale, enabled bool) error {
	filtered := make([]policy.Rule, 0, len(p.Rules))
	for _, rule := range p.Rules {
		missing := (rule.Outbound == "vpn-sub" && !vless) || (rule.Outbound == "tailscale-exit" && !tailscale)
		if !missing {
			filtered = append(filtered, rule)
			continue
		}
		initial := (rule.Name == "vpn-sub" && rule.Outbound == "vpn-sub" && reflect.DeepEqual(rule.Filter, []string{"geosite:ru-blocked", "geoip:ru-blocked", "geosite:youtube", "geosite:telegram", "geoip:telegram", "geosite:whatsapp", "domain:ifconfig.me"})) ||
			(rule.Name == "vpn-static" && rule.Outbound == "tailscale-exit" && reflect.DeepEqual(rule.Filter, []string{"geosite:openai", "geosite:cursor", "geosite:anthropic", "domain:2ip.io"}))
		if !enabled || !initial || len(rule.Filter) == 0 {
			return fmt.Errorf("rule %q requires unavailable outbound %q", rule.Name, rule.Outbound)
		}
		fmt.Fprintf(os.Stderr, "Omitting initial rule %q: %s is unavailable.\n", rule.Name, rule.Outbound)
	}
	p.Rules = filtered
	return nil
}

func parseSubscription(payload []byte) ([]map[string]any, []string, error) {
	text := strings.TrimSpace(string(payload))
	if !strings.Contains(text, "vless://") {
		encoded := strings.Join(strings.Fields(text), "")
		var decoded []byte
		var err error
		for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
			decoded, err = enc.DecodeString(encoded)
			if err == nil {
				break
			}
		}
		if err != nil {
			return nil, nil, fmt.Errorf("subscription is not valid base64")
		}
		text = string(decoded)
	}
	var nodes []map[string]any
	var tags []string
	seen := map[string]bool{}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(strings.ToLower(line), "vless://") {
			continue
		}
		u, err := url.Parse(line)
		if err != nil || u.User == nil || u.Hostname() == "" {
			continue
		}
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			continue
		}
		uuid := u.User.Username()
		if !uuidPattern.MatchString(uuid) {
			continue
		}
		query := u.Query()
		security := query.Get("security")
		if security == "" {
			security = "none"
		}
		transport := query.Get("type")
		if transport == "" {
			transport = "tcp"
		}
		if security != "none" && security != "tls" && security != "reality" {
			continue
		}
		if transport != "tcp" && transport != "ws" && transport != "grpc" && transport != "httpupgrade" {
			continue
		}
		flow := query.Get("flow")
		if flow != "" && flow != "xtls-rprx-vision" {
			continue
		}
		if security == "reality" && query.Get("pbk") == "" {
			continue
		}
		sum := sha256.Sum256([]byte(line))
		tag := fmt.Sprintf("sub-%x", sum[:6])
		if seen[tag] {
			continue
		}
		seen[tag] = true
		node := map[string]any{"type": "vless", "tag": tag, "server": u.Hostname(), "server_port": port, "uuid": uuid}
		if flow != "" {
			node["flow"] = flow
		}
		if security != "none" {
			tls := map[string]any{"enabled": true}
			if sni := query.Get("sni"); sni != "" {
				tls["server_name"] = sni
			}
			if alpn := query.Get("alpn"); alpn != "" {
				tls["alpn"] = strings.Split(alpn, ",")
			}
			if fp := query.Get("fp"); fp != "" {
				tls["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
			}
			if security == "reality" {
				tls["reality"] = map[string]any{"enabled": true, "public_key": query.Get("pbk"), "short_id": query.Get("sid")}
			}
			node["tls"] = tls
		}
		switch transport {
		case "ws":
			t := map[string]any{"type": "ws", "path": query.Get("path")}
			if host := query.Get("host"); host != "" {
				t["headers"] = map[string]string{"Host": host}
			}
			node["transport"] = t
		case "grpc":
			node["transport"] = map[string]any{"type": "grpc", "service_name": query.Get("serviceName")}
		case "httpupgrade":
			node["transport"] = map[string]any{"type": "httpupgrade", "path": query.Get("path"), "host": query.Get("host")}
		}
		if net.ParseIP(u.Hostname()) == nil {
			node["domain_resolver"] = "local-dns"
		}
		nodes = append(nodes, node)
		tags = append(tags, tag)
	}
	if len(nodes) == 0 {
		return nil, nil, fmt.Errorf("no supported VLESS nodes in subscription")
	}
	return nodes, tags, nil
}
