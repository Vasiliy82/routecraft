// Package compiler translates RouteCraft policies into sing-box route fragments.
package compiler

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"sort"
	"strconv"

	"github.com/vasiliy82/routecraft/internal/policy"
)

type Input struct {
	Policy     policy.Policy
	Outbounds  policy.Outbounds
	Categories policy.Categories
}

// Artifacts is a fragment, not a complete sing-box configuration. The runtime
// provider must supply inbounds, DNS and any referenced external outbound tags.
type Artifacts struct {
	Route     Route            `json:"route"`
	Outbounds []map[string]any `json:"outbounds"`
}

type Route struct {
	Rules   []map[string]any `json:"rules"`
	RuleSet []map[string]any `json:"rule_set,omitempty"`
	Final   string           `json:"final,omitempty"`
}

func Compile(in Input) (Artifacts, error) {
	var result Artifacts
	if err := policy.Validate(in.Policy, in.Outbounds, in.Categories); err != nil {
		return result, err
	}
	result.Route.Rules = []map[string]any{{"action": "sniff"}}
	result.Outbounds = []map[string]any{}
	names := make([]string, 0, len(in.Outbounds.Outbounds))
	for name := range in.Outbounds.Outbounds {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		outbound := in.Outbounds.Outbounds[name]
		if outbound.Type == "direct" {
			result.Outbounds = append(result.Outbounds, map[string]any{"type": "direct", "tag": name})
		}
	}
	usedSets := make(map[string]string)
	for _, rule := range in.Policy.Rules {
		outbound := in.Outbounds.Outbounds[rule.Outbound]
		if outbound.Type == "gateway" {
			return Artifacts{}, fmt.Errorf("rule %q: gateway transport is not implemented", rule.Name)
		}
		var tag string
		switch outbound.Type {
		case "direct":
			tag = rule.Outbound
		case "sing-box-tag":
			tag = outbound.Tag
		}
		if rule.Filter == nil {
			if outbound.Type == "reject" {
				result.Route.Rules = append(result.Route.Rules, map[string]any{"action": "reject"})
			} else {
				result.Route.Final = tag
			}
			continue
		}
		alternatives := make([]map[string]any, 0, len(rule.Filter))
		for _, filter := range rule.Filter {
			kind, value, _ := policy.SplitFilter(filter)
			condition := make(map[string]any)
			switch kind {
			case "geosite", "geoip":
				setTag := kind + "-" + value
				usedSets[setTag] = in.Categories.Categories[kind+":"+value]
				condition["rule_set"] = []string{setTag}
			case "domain":
				condition["domain"] = []string{value}
			case "domainsuffix":
				condition["domain_suffix"] = []string{value}
			case "domainkeyword":
				condition["domain_keyword"] = []string{value}
			case "ip":
				addr, _ := netip.ParseAddr(value)
				condition["ip_cidr"] = []string{netip.PrefixFrom(addr, addr.BitLen()).String()}
			case "ipnet":
				condition["ip_cidr"] = []string{value}
			case "port":
				port, _ := strconv.Atoi(value)
				condition["port"] = []int{port}
			case "network":
				condition["network"] = value
			}
			alternatives = append(alternatives, condition)
		}
		compiled := map[string]any{"type": "logical", "mode": "or", "rules": alternatives}
		if outbound.Type == "reject" {
			compiled["action"] = "reject"
		} else {
			compiled["action"] = "route"
			compiled["outbound"] = tag
		}
		result.Route.Rules = append(result.Route.Rules, compiled)
	}
	setNames := make([]string, 0, len(usedSets))
	for name := range usedSets {
		setNames = append(setNames, name)
	}
	sort.Strings(setNames)
	for _, name := range setNames {
		result.Route.RuleSet = append(result.Route.RuleSet, map[string]any{
			"type": "local", "tag": name, "format": "binary", "path": usedSets[name],
		})
	}
	return result, nil
}

func Marshal(artifacts Artifacts) ([]byte, error) {
	data, err := json.MarshalIndent(artifacts, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}
