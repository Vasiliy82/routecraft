package policy

import (
	"strings"
	"testing"
)

func TestParseRejectsUnknownFieldsAndDuplicateKeys(t *testing.T) {
	for _, data := range []string{
		"version: 1\nversion: 1\nrules: []\n",
		"version: 1\nrules: []\nextra: true\n",
		"version: 1\nrules: []\n---\nversion: 1\n",
	} {
		if _, err := Parse([]byte(data)); err == nil {
			t.Errorf("Parse(%q) unexpectedly succeeded", data)
		}
	}
}

func TestValidatePolicyErrors(t *testing.T) {
	outbounds := Outbounds{Version: 1, Outbounds: map[string]Outbound{"direct": {Type: "direct"}}}
	index := Categories{Version: 1, Categories: map[string]string{"geosite:known": "/tmp/known.srs"}}
	valid := Rule{Name: "default", Outbound: "direct"}
	tests := []struct {
		name  string
		rules []Rule
		want  string
	}{
		{"empty", nil, "default"},
		{"unknown outbound", []Rule{{Name: "default", Outbound: "missing"}}, "unknown outbound"},
		{"missing category", []Rule{{Name: "first", Filter: []string{"geosite:missing"}, Outbound: "direct"}, valid}, "geosite:missing"},
		{"duplicate", []Rule{{Name: "default", Filter: []string{"domain:example.com"}, Outbound: "direct"}, valid}, "duplicate"},
		{"missing default", []Rule{{Name: "first", Filter: []string{"network:tcp"}, Outbound: "direct"}}, "default"},
		{"default not last", []Rule{valid, {Name: "second", Outbound: "direct"}}, "default"},
		{"empty filter", []Rule{{Name: "first", Filter: []string{}, Outbound: "direct"}, valid}, "empty filter"},
		{"bad port", []Rule{{Name: "first", Filter: []string{"port:65536"}, Outbound: "direct"}, valid}, "invalid port"},
		{"bad domain", []Rule{{Name: "first", Filter: []string{"domain:bad..example"}, Outbound: "direct"}, valid}, "invalid domain"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := Validate(Policy{Version: 1, Rules: tc.rules}, outbounds, index)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("got %v; want error containing %q", err, tc.want)
			}
		})
	}
}

func TestSplitFilterCanonicalizesAddresses(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"domain:EXAMPLE.COM", "example.com"},
		{"ipnet:192.0.2.23/24", "192.0.2.0/24"},
		{"ip:2001:db8::1", "2001:db8::1"},
	} {
		_, got, err := SplitFilter(tc.in)
		if err != nil || got != tc.want {
			t.Errorf("SplitFilter(%q) = %q, %v; want %q", tc.in, got, err, tc.want)
		}
	}
}
