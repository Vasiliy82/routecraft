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
	if err := build(policyPath, "", "", dir, "", "", "192.0.2.53", output, false); err == nil {
		t.Fatal("missing VPN must fail without explicit omission")
	}
	if err := build(policyPath, "", "", dir, "", "", "192.0.2.53", output, true); err != nil {
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
			if err := build(path, "", "", dir, "", "", "192.0.2.53", filepath.Join(dir, "out"), true); err == nil {
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
	if err := build(policyPath, sub, "", dir, "", "", "192.0.2.53", output, true); err != nil {
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
	if err := build(policyPath, "", key, filepath.Join(dir, "generation"), "https://example.invalid", "100.64.0.1", "192.0.2.53", output, true); err != nil {
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
