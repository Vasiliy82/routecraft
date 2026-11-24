package compiler

import (
	"bytes"
	"testing"

	"github.com/vasiliy82/routecraft/internal/policy"
)

func TestCompilePreservesOrderAndUsesLogicalOR(t *testing.T) {
	in := Input{
		Policy: policy.Policy{Version: 1, Rules: []policy.Rule{
			{Name: "first", Filter: []string{"domain:example.org", "port:443", "network:udp"}, Outbound: "reject"},
			{Name: "second", Filter: []string{"ipnet:192.0.2.0/24"}, Outbound: "direct"},
			{Name: "default", Outbound: "direct"},
		}},
		Outbounds:  policy.Outbounds{Version: 1, Outbounds: map[string]policy.Outbound{"reject": {Type: "reject"}, "direct": {Type: "direct"}}},
		Categories: policy.Categories{Version: 1, Categories: map[string]string{}},
	}
	a, err := Compile(in)
	if err != nil {
		t.Fatal(err)
	}
	if len(a.Route.Rules) != 3 || a.Route.Rules[0]["action"] != "sniff" || a.Route.Rules[1]["action"] != "reject" || a.Route.Rules[2]["outbound"] != "direct" {
		t.Fatalf("unexpected order: %#v", a.Route.Rules)
	}
	if a.Route.Rules[1]["mode"] != "or" || len(a.Route.Rules[1]["rules"].([]map[string]any)) != 3 {
		t.Fatalf("filter alternatives are not OR: %#v", a.Route.Rules[1])
	}
	if a.Route.Final != "direct" {
		t.Fatalf("unexpected default %q", a.Route.Final)
	}
	first, _ := Marshal(a)
	for i := 0; i < 20; i++ {
		again, err := Compile(in)
		if err != nil {
			t.Fatal(err)
		}
		next, _ := Marshal(again)
		if !bytes.Equal(first, next) {
			t.Fatal("compile is not deterministic")
		}
	}
}

func TestGatewayDoesNotSilentlyBecomeDirect(t *testing.T) {
	in := Input{
		Policy:     policy.Policy{Version: 1, Rules: []policy.Rule{{Name: "default", Outbound: "gw"}}},
		Outbounds:  policy.Outbounds{Version: 1, Outbounds: map[string]policy.Outbound{"gw": {Type: "gateway", Via: "192.0.2.1", Interface: "eth0"}}},
		Categories: policy.Categories{Version: 1},
	}
	if _, err := Compile(in); err == nil {
		t.Fatal("unimplemented gateway was accepted")
	}
}

func TestCompileSplitDNSProjectsDomainAlternatives(t *testing.T) {
	in := Input{
		Policy: policy.Policy{Version: 1, Rules: []policy.Rule{
			{Name: "vpn", Filter: []string{"domainsuffix:example.org", "geosite:media", "geoip:media", "port:443"}, Outbound: "vpn"},
			{Name: "block", Filter: []string{"domain:bad.example.org"}, Outbound: "reject"},
			{Name: "ip", Filter: []string{"ip:192.0.2.5"}, Outbound: "ip-only"},
			{Name: "default", Outbound: "direct"},
		}, DNS: map[string]policy.DNSProfile{
			"direct": {Type: "udp", Server: "192.0.2.53"},
			"vpn":    {Type: "https", Server: "198.51.100.53", ServerName: "dns.example.org"},
		}},
		Outbounds: policy.Outbounds{Version: 1, Outbounds: map[string]policy.Outbound{
			"vpn": {Type: "sing-box-tag", Tag: "tunnel"}, "ip-only": {Type: "sing-box-tag", Tag: "other"},
			"direct": {Type: "direct"}, "reject": {Type: "reject"},
		}},
		Categories: policy.Categories{Version: 1, Categories: map[string]string{
			"geosite:media": "domains.srs", "geoip:media": "addresses.srs",
		}},
	}
	a, err := Compile(in)
	if err != nil {
		t.Fatal(err)
	}
	dns := a.DNS
	if dns == nil || dns.Final != "routecraft-dns-direct" || len(dns.Rules) != 2 {
		t.Fatalf("unexpected DNS policy: %#v", dns)
	}
	first := dns.Rules[0]
	filters := first["rules"].([]map[string]any)
	if first["server"] != "routecraft-dns-vpn" || first["mode"] != "or" || len(filters) != 2 ||
		filters[0]["domain_suffix"].([]string)[0] != "example.org" || filters[1]["rule_set"].([]string)[0] != "geosite-media" {
		t.Fatalf("unexpected first DNS rule: %#v", first)
	}
	if dns.Rules[1]["rcode"] != "REFUSED" || dns.Servers[1]["detour"] != "tunnel" || len(a.Route.RuleSet) != 2 {
		t.Fatalf("unexpected DNS actions or shared rule sets: %#v, %#v", dns, a.Route.RuleSet)
	}
	delete(in.Policy.DNS, "vpn")
	if _, err := Compile(in); err == nil {
		t.Fatal("missing VPN DNS profile silently accepted")
	}
}
