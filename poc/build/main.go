// Command build creates the single sing-box configuration used by the PoC.
package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/vasiliy82/routecraft/internal/compiler"
	"github.com/vasiliy82/routecraft/internal/policy"
)

func main() {
	settingsPath := flag.String("policy", "/tmp/routecraft-poc/policy.yaml", "policy YAML")
	subscriptionPath := flag.String("subscription", "/tmp/routecraft-poc/subscription.raw", "downloaded subscription")
	keyPath := flag.String("headscale-key", "/tmp/routecraft-poc/headscale.key", "Tailscale or Headscale auth key")
	dataDir := flag.String("data", "/tmp/routecraft-poc", "rule-set and state directory")
	control := flag.String("headscale", "https://controlplane.tailscale.com", "Tailscale or Headscale URL")
	exitNode := flag.String("exit-node", "", "Tailscale exit node")
	dnsUpstream := flag.String("dns", "", "DNS upstream reachable from the gateway")
	output := flag.String("output", "/tmp/routecraft-poc/sing-box.json", "generated sing-box configuration")
	flag.Parse()
	if err := build(*settingsPath, *subscriptionPath, *keyPath, *dataDir, *control, *exitNode, *dnsUpstream, *output); err != nil {
		fmt.Fprintln(os.Stderr, "routecraft-poc:", err)
		os.Exit(1)
	}
}

func build(settingsPath, subscriptionPath, keyPath, dataDir, control, exitNode, dnsUpstream, output string) error {
	if strings.TrimSpace(control) == "" || strings.TrimSpace(exitNode) == "" || strings.TrimSpace(dnsUpstream) == "" {
		return fmt.Errorf("control URL, exit node and DNS upstream are required")
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
	sub, err := os.ReadFile(subscriptionPath)
	if err != nil {
		return err
	}
	nodes, tags, err := parseSubscription(sub)
	if err != nil {
		return err
	}
	key, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(key)) == "" {
		return fmt.Errorf("Headscale key is empty")
	}
	compiled.Outbounds = append(compiled.Outbounds, nodes...)
	compiled.Outbounds = append(compiled.Outbounds, map[string]any{
		"type": "urltest", "tag": "vpn-sub", "outbounds": tags,
		"url": "https://www.gstatic.com/generate_204", "interval": "5m", "tolerance": 100,
	})
	// Diagnostic listeners exercise each transport without changing the system route.
	rules := []map[string]any{
		{"inbound": []string{"test-vless"}, "action": "route", "outbound": "vpn-sub"},
		{"inbound": []string{"test-exit"}, "action": "route", "outbound": "tailscale-exit"},
		{"inbound": []string{"test-direct"}, "action": "route", "outbound": "direct"},
	}
	// Sniff first so the test-only domain can be matched for transparent traffic.
	rules = append(rules, compiled.Route.Rules[0])
	rules = append(rules, compiled.Route.Rules[1:]...)
	config := map[string]any{
		"log": map[string]any{"level": "debug"},
		"dns": map[string]any{"servers": []any{map[string]any{"type": "udp", "tag": "local-dns", "server": dnsUpstream}}, "final": "local-dns", "reverse_mapping": true},
		"inbounds": []any{
			map[string]any{"type": "tproxy", "tag": "gateway", "listen": "0.0.0.0", "listen_port": 12345},
			map[string]any{"type": "mixed", "tag": "test-direct", "listen": "127.0.0.1", "listen_port": 1080},
			map[string]any{"type": "mixed", "tag": "test-vless", "listen": "127.0.0.1", "listen_port": 1081},
			map[string]any{"type": "mixed", "tag": "test-exit", "listen": "127.0.0.1", "listen_port": 1082},
		},
		"outbounds": compiled.Outbounds,
		"endpoints": []any{map[string]any{
			"type": "tailscale", "tag": "tailscale-exit", "state_directory": filepath.Join(dataDir, "tailscale-state"),
			"hostname": "routecraft-poc", "control_url": control, "auth_key": strings.TrimSpace(string(key)),
			"exit_node": exitNode, "accept_routes": false, "exit_node_allow_lan_access": true, "system_interface": false,
		}},
		"route": map[string]any{"rules": rules, "rule_set": compiled.Route.RuleSet, "final": compiled.Route.Final, "default_domain_resolver": "local-dns"},
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
		if len(uuid) != 36 {
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
