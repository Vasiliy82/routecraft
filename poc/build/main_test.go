package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseSubscriptionRejectsMalformedUUID(t *testing.T) {
	invalid := []byte("vless://zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz@example.invalid:443")
	if _, _, err := parseSubscription(invalid); err == nil {
		t.Fatal("expected invalid UUID to be rejected")
	}
	valid := []byte("vless://00000000-0000-4000-8000-000000000000@example.invalid:443")
	if nodes, _, err := parseSubscription(valid); err != nil || len(nodes) != 1 {
		t.Fatalf("valid fixture: %v, %v", nodes, err)
	}
}

func TestBuildWithoutVPNRequiresExplicitOmission(t *testing.T) {
	dir := t.TempDir()
	policyPath := filepath.Join(dir, "policy.yaml")
	output := filepath.Join(dir, "out.json")
	input := "rules:\n  - name: vpn-static\n    filter: [geosite:openai, geosite:cursor, geosite:anthropic, domain:2ip.io]\n    outbound: tailscale-exit\n  - name: vpn-sub\n    filter: [geosite:ru-blocked, geoip:ru-blocked, geosite:youtube, geosite:telegram, geoip:telegram, geosite:whatsapp, domain:ifconfig.me]\n    outbound: vpn-sub\n  - name: default\n    outbound: direct\n"
	if err := os.WriteFile(policyPath, []byte(input), 0600); err != nil {
		t.Fatal(err)
	}
	if err := build(policyPath, "", "", dir, "", "", "192.0.2.53", output, false, false); err == nil {
		t.Fatal("missing VPN must fail without explicit omission")
	}
	if err := build(policyPath, "", "", dir, "", "", "192.0.2.53", output, true, false); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	for _, unwanted := range []string{"tailscale-exit", "vpn-sub", "test-exit", "test-vless", "example.org", "example.net"} {
		if strings.Contains(string(data), unwanted) {
			t.Errorf("configuration retains %q", unwanted)
		}
	}
	if _, ok := config["endpoints"]; ok {
		t.Fatal("unexpected endpoint")
	}
}

func TestBuildRejectsOmissionOfCustomOrDefaultVPNRule(t *testing.T) {
	for _, tc := range []struct{ name, input string }{
		{"custom", "rules:\n  - name: custom\n    filter: [domain:example.org]\n    outbound: vpn-sub\n  - name: default\n    outbound: direct\n"},
		{"modified initial name", "rules:\n  - name: vpn-sub\n    filter: [domain:example.org]\n    outbound: vpn-sub\n  - name: default\n    outbound: direct\n"},
		{"default", "rules:\n  - name: vpn-sub\n    outbound: vpn-sub\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "policy.yaml")
			if err := os.WriteFile(path, []byte(tc.input), 0600); err != nil {
				t.Fatal(err)
			}
			if err := build(path, "", "", dir, "", "", "192.0.2.53", filepath.Join(dir, "out"), true, false); err == nil {
				t.Fatal("expected rejection")
			}
		})
	}
}

func TestBuildWithOnlySubscription(t *testing.T) {
	dir := t.TempDir()
	policyPath := filepath.Join(dir, "policy.yaml")
	input := "rules:\n  - name: vpn-static\n    filter: [geosite:openai, geosite:cursor, geosite:anthropic, domain:2ip.io]\n    outbound: tailscale-exit\n  - name: retained\n    filter: [domain:example.net]\n    outbound: vpn-sub\n  - name: default\n    outbound: direct\n"
	if err := os.WriteFile(policyPath, []byte(input), 0600); err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(dir, "subscription")
	if err := os.WriteFile(sub, []byte("vless://00000000-0000-4000-8000-000000000000@example.invalid:443"), 0600); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(dir, "out.json")
	if err := build(policyPath, sub, "", dir, "", "", "192.0.2.53", output, true, false); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"vpn-sub"`) || !strings.Contains(string(data), "example.net") {
		t.Fatal("subscription policy not retained")
	}
	if strings.Contains(string(data), "tailscale-exit") || strings.Contains(string(data), "test-exit") {
		t.Fatal("unexpected Tailscale reference")
	}
}

func TestBuildKeepsTailscaleStateOutsideRuleGeneration(t *testing.T) {
	dir := t.TempDir()
	policyPath := filepath.Join(dir, "policy.yaml")
	input := "rules:\n  - name: retained\n    filter: [domain:example.net]\n    outbound: tailscale-exit\n  - name: default\n    outbound: direct\n"
	if err := os.WriteFile(policyPath, []byte(input), 0600); err != nil {
		t.Fatal(err)
	}
	key := filepath.Join(dir, "key")
	if err := os.WriteFile(key, []byte("fake-key"), 0600); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(dir, "identity")
	t.Setenv("ROUTECRAFT_TAILSCALE_STATE_DIR", state)
	output := filepath.Join(dir, "out.json")
	if err := build(policyPath, "", key, filepath.Join(dir, "generation"), "https://example.invalid", "100.64.0.1", "192.0.2.53", output, true, false); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Endpoints []struct {
			State string `json:"state_directory"`
		} `json:"endpoints"`
	}
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	if len(config.Endpoints) != 1 || config.Endpoints[0].State != state {
		t.Fatalf("unexpected endpoint state: %+v", config.Endpoints)
	}
}

func TestBuildDerivesDNSAndPinsSubscriptionNode(t *testing.T) {
	dir := t.TempDir()
	settings := filepath.Join(dir, "policy.yaml")
	subscription := filepath.Join(dir, "subscription")
	output := filepath.Join(dir, "sing-box.json")
	input := "rules:\n  - name: ip-only\n    filter: [ipnet:203.0.113.0/24]\n    outbound: direct\n" +
		"  - name: video\n    filter: [domain:example.net]\n    outbound: vpn-sub\n  - name: default\n    outbound: direct\n"
	if err := os.WriteFile(settings, []byte(input), 0600); err != nil {
		t.Fatal(err)
	}
	first := "vless://00000000-0000-4000-8000-000000000000@first.example:443"
	second := "vless://00000000-0000-4000-8000-000000000000@second.example:443"
	for _, nodes := range []string{first + "\n" + second, second + "\n" + first} {
		if err := os.WriteFile(subscription, []byte(nodes), 0600); err != nil {
			t.Fatal(err)
		}
		_, tags, err := parseSubscription([]byte(nodes))
		if err != nil {
			t.Fatal(err)
		}
		if err := build(settings, subscription, "", dir, "", "", "192.0.2.53", output, false, false); err != nil {
			t.Fatal(err)
		}
		data, err := os.ReadFile(output)
		if err != nil {
			t.Fatal(err)
		}
		var config struct {
			DNS struct {
				Servers []map[string]any
				Rules   []map[string]any
				Final   string
			}
			Outbounds []map[string]any
			Route     struct{ Rules []map[string]any }
		}
		if err := json.Unmarshal(data, &config); err != nil {
			t.Fatal(err)
		}
		if config.DNS.Final != "routecraft-dns-direct" {
			t.Fatalf("unexpected default resolver: %s", config.DNS.Final)
		}
		foundDNS := false
		for _, server := range config.DNS.Servers {
			if server["tag"] == "routecraft-dns-vpn-sub" {
				foundDNS = server["detour"] == "vpn-sub" && server["type"] == "https"
			}
		}
		if !foundDNS || config.DNS.Rules[len(config.DNS.Rules)-1]["server"] != "routecraft-dns-vpn-sub" {
			t.Fatal("VLESS domain DNS must use the subscription outbound")
		}
		selector := config.Outbounds[len(config.Outbounds)-1]
		if selector["tag"] != "vpn-sub" || selector["type"] != "selector" || selector["default"] != tags[0] {
			t.Fatalf("subscription node is not pinned: %v", selector)
		}
		if !strings.Contains(string(data), `"tag": "routecraft-dns"`) ||
			!strings.Contains(string(data), `"domain_regex"`) ||
			config.Route.Rules[len(config.Route.Rules)-1]["outbound"] != "vpn-sub" {
			t.Fatal("generated gateway must expose policy DNS and share the outbound for named connections")
		}
	}
}
