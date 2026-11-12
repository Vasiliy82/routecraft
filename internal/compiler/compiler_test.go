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
