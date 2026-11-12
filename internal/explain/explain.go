// Package explain performs a conservative, side-effect-free policy simulation.
package explain

import (
	"fmt"
	"net/netip"
	"strings"

	"github.com/vasiliy82/routecraft/internal/policy"
)

type Target struct {
	Domain  string
	IP      string
	Port    int
	Network string
}

type Result struct {
	Status   string `json:"status"`
	Rule     string `json:"rule"`
	Index    int    `json:"index"`
	Filter   string `json:"filter,omitempty"`
	Outbound string `json:"outbound,omitempty"`
	Reason   string `json:"reason"`
}

type match int

const (
	no match = iota
	yes
	unknown
)

// Evaluate never assumes that a category matched when no evaluator is available.
// Unknown information in a higher-priority rule stops evaluation conservatively.
func Evaluate(p policy.Policy, t Target) (Result, error) {
	if t.Domain == "" && t.IP == "" && t.Port == 0 && t.Network == "" {
		return Result{}, fmt.Errorf("supply at least one target field")
	}
	if t.Domain != "" {
		_, d, err := policy.SplitFilter("domain:" + t.Domain)
		if err != nil {
			return Result{}, err
		}
		t.Domain = d
	}
	var ip netip.Addr
	if t.IP != "" {
		var err error
		ip, err = netip.ParseAddr(t.IP)
		if err != nil || ip.Zone() != "" {
			return Result{}, fmt.Errorf("invalid IP address %q", t.IP)
		}
	}
	if t.Port < 0 || t.Port > 65535 {
		return Result{}, fmt.Errorf("invalid port %d", t.Port)
	}
	if t.Network != "" && t.Network != "tcp" && t.Network != "udp" {
		return Result{}, fmt.Errorf("invalid network %q", t.Network)
	}
	for i, rule := range p.Rules {
		if rule.Filter == nil {
			return Result{Status: "matched", Rule: rule.Name, Index: i + 1, Outbound: rule.Outbound, Reason: "final default; static simulation only"}, nil
		}
		var uncertain string
		for _, raw := range rule.Filter {
			kind, value, err := policy.SplitFilter(raw)
			if err != nil {
				return Result{}, fmt.Errorf("rule %q: %w", rule.Name, err)
			}
			outcome := no
			switch kind {
			case "geosite", "geoip":
				outcome = unknown
			case "domain", "domainsuffix", "domainkeyword":
				if t.Domain == "" {
					outcome = unknown
				} else if kind == "domain" && t.Domain == value ||
					kind == "domainsuffix" && (t.Domain == value || strings.HasSuffix(t.Domain, "."+value)) ||
					kind == "domainkeyword" && strings.Contains(t.Domain, value) {
					outcome = yes
				}
			case "ip", "ipnet":
				if !ip.IsValid() {
					outcome = unknown
				} else if kind == "ip" && ip.String() == value {
					outcome = yes
				} else if kind == "ipnet" {
					prefix, _ := netip.ParsePrefix(value)
					if prefix.Contains(ip) {
						outcome = yes
					}
				}
			case "port":
				if t.Port == 0 {
					outcome = unknown
				} else if fmt.Sprint(t.Port) == value {
					outcome = yes
				}
			case "network":
				if t.Network == "" {
					outcome = unknown
				} else if t.Network == value {
					outcome = yes
				}
			}
			if outcome == yes {
				return Result{Status: "matched", Rule: rule.Name, Index: i + 1, Filter: raw, Outbound: rule.Outbound, Reason: "first matching rule; static simulation only"}, nil
			}
			if outcome == unknown && uncertain == "" {
				uncertain = raw
			}
		}
		if uncertain != "" {
			return Result{Status: "indeterminate", Rule: rule.Name, Index: i + 1, Filter: uncertain, Reason: "missing target information or category evaluation; later rules cannot be determined safely"}, nil
		}
	}
	return Result{}, fmt.Errorf("policy has no final default")
}
