package compiler

import "github.com/vasiliy82/routecraft/internal/policy"

// DNS contains the public DNS rules and upstreams for a policy with DNS profiles.
type DNS struct {
	Servers      []map[string]any `json:"servers"`
	Rules        []map[string]any `json:"rules,omitempty"`
	Final        string           `json:"final,omitempty"`
	DisableCache bool             `json:"disable_cache"`
}

func dnsTag(outbound string) string { return "routecraft-dns-" + outbound }

func dnsServer(name string, outbound policy.Outbound, profile policy.DNSProfile) map[string]any {
	server := map[string]any{"type": profile.Type, "tag": dnsTag(name), "server": profile.Server}
	if profile.Port != 0 {
		server["server_port"] = profile.Port
	}
	if profile.Type == "https" {
		server["tls"] = map[string]any{"server_name": profile.ServerName}
	}
	if outbound.Type == "sing-box-tag" {
		server["detour"] = outbound.Tag
	}
	return server
}

func dnsRule(name string, outbound policy.Outbound, alternatives []map[string]any) map[string]any {
	rule := map[string]any{"type": "logical", "mode": "or", "rules": alternatives}
	if outbound.Type == "reject" {
		rule["action"] = "predefined"
		rule["rcode"] = "REFUSED"
	} else {
		rule["action"] = "route"
		rule["server"] = dnsTag(name)
	}
	return rule
}

func (d *DNS) setDefault(name string, outbound policy.Outbound) {
	if outbound.Type == "reject" {
		d.Rules = append(d.Rules, map[string]any{"domain_regex": []string{".*"}, "action": "predefined", "rcode": "REFUSED"})
		return
	}
	d.Final = dnsTag(name)
}
