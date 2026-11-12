// Package policy parses and validates declarative routing policies.
package policy

import (
	"bytes"
	"fmt"
	"io"
	"net/netip"
	"regexp"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

type Policy struct {
	Version int    `yaml:"version"`
	Rules   []Rule `yaml:"rules"`
}

type Rule struct {
	Name     string   `yaml:"name"`
	Filter   []string `yaml:"filter"`
	Outbound string   `yaml:"outbound"`
}

type Outbounds struct {
	Version   int                 `yaml:"version"`
	Outbounds map[string]Outbound `yaml:"outbounds"`
}

type Outbound struct {
	Type      string `yaml:"type"`
	Tag       string `yaml:"tag,omitempty"`
	Via       string `yaml:"via,omitempty"`
	Interface string `yaml:"interface,omitempty"`
}

// Categories are locally available rule sets, indexed by e.g. geosite:openai.
type Categories struct {
	Version    int               `yaml:"version"`
	Categories map[string]string `yaml:"categories"`
}

var namePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`)
var domainLabelPattern = regexp.MustCompile(`^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`)

func parse(data []byte, target any) error {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("invalid YAML: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple YAML documents are not supported")
		}
		return fmt.Errorf("invalid YAML: %w", err)
	}
	return nil
}

func Parse(data []byte) (Policy, error) {
	var p Policy
	err := parse(data, &p)
	return p, err
}

func ParseOutbounds(data []byte) (Outbounds, error) {
	var o Outbounds
	err := parse(data, &o)
	return o, err
}

func ParseCategories(data []byte) (Categories, error) {
	var c Categories
	err := parse(data, &c)
	return c, err
}

// SplitFilter validates the syntax and returns a canonical kind and value.
func SplitFilter(filter string) (string, string, error) {
	kind, value, ok := strings.Cut(filter, ":")
	if !ok || value == "" || strings.TrimSpace(value) != value {
		return "", "", fmt.Errorf("invalid filter %q", filter)
	}
	switch kind {
	case "geosite", "geoip":
		if !namePattern.MatchString(value) {
			return "", "", fmt.Errorf("invalid category %q", value)
		}
	case "domain", "domainsuffix":
		if len(value) > 253 || strings.HasSuffix(value, ".") {
			return "", "", fmt.Errorf("invalid domain %q", value)
		}
		for _, label := range strings.Split(value, ".") {
			if !domainLabelPattern.MatchString(label) {
				return "", "", fmt.Errorf("invalid domain %q", value)
			}
		}
		value = strings.ToLower(value)
	case "domainkeyword":
		if strings.ContainsAny(value, " \t\r\n") {
			return "", "", fmt.Errorf("invalid domain keyword %q", value)
		}
		value = strings.ToLower(value)
	case "ip":
		addr, err := netip.ParseAddr(value)
		if err != nil || addr.Zone() != "" {
			return "", "", fmt.Errorf("invalid IP address %q", value)
		}
		value = addr.String()
	case "ipnet":
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return "", "", fmt.Errorf("invalid CIDR %q", value)
		}
		value = prefix.Masked().String()
	case "port":
		port, err := strconv.Atoi(value)
		if err != nil || port < 1 || port > 65535 || strconv.Itoa(port) != value {
			return "", "", fmt.Errorf("invalid port %q", value)
		}
	case "network":
		if value != "tcp" && value != "udp" {
			return "", "", fmt.Errorf("invalid network %q", value)
		}
	default:
		return "", "", fmt.Errorf("unsupported filter type %q", kind)
	}
	return kind, value, nil
}

// Validate checks all references before any network state can be changed.
func Validate(p Policy, o Outbounds, c Categories) error {
	if p.Version != 1 || o.Version != 1 || c.Version != 1 {
		return fmt.Errorf("policy, outbounds and categories must all use version 1")
	}
	if len(p.Rules) == 0 {
		return fmt.Errorf("policy must contain a final default rule")
	}
	for name, outbound := range o.Outbounds {
		if !namePattern.MatchString(name) {
			return fmt.Errorf("invalid outbound name %q", name)
		}
		switch outbound.Type {
		case "direct", "reject":
			if outbound.Tag != "" || outbound.Via != "" || outbound.Interface != "" {
				return fmt.Errorf("outbound %q: fields do not match type %s", name, outbound.Type)
			}
		case "sing-box-tag":
			if !namePattern.MatchString(outbound.Tag) || outbound.Via != "" || outbound.Interface != "" {
				return fmt.Errorf("outbound %q: valid tag is required", name)
			}
		case "gateway":
			if _, err := netip.ParseAddr(outbound.Via); err != nil || outbound.Interface == "" || outbound.Tag != "" {
				return fmt.Errorf("outbound %q: gateway requires IP via and interface", name)
			}
		case "tailscale-exit":
			return fmt.Errorf("outbound %q: tailscale-exit is not implemented", name)
		default:
			return fmt.Errorf("outbound %q: unsupported type %q", name, outbound.Type)
		}
	}
	seen := make(map[string]bool)
	for i, rule := range p.Rules {
		if !namePattern.MatchString(rule.Name) || seen[rule.Name] {
			return fmt.Errorf("rule %d: invalid or duplicate name %q", i+1, rule.Name)
		}
		seen[rule.Name] = true
		if _, ok := o.Outbounds[rule.Outbound]; !ok {
			return fmt.Errorf("rule %q: unknown outbound %q", rule.Name, rule.Outbound)
		}
		if rule.Filter == nil && i != len(p.Rules)-1 {
			return fmt.Errorf("rule %q: default must be last", rule.Name)
		}
		if rule.Filter != nil && len(rule.Filter) == 0 {
			return fmt.Errorf("rule %q: empty filter is not a default", rule.Name)
		}
		if i == len(p.Rules)-1 && rule.Filter != nil {
			return fmt.Errorf("rule %q: final default rule is required", rule.Name)
		}
		for _, f := range rule.Filter {
			kind, value, err := SplitFilter(f)
			if err != nil {
				return fmt.Errorf("rule %q: %w", rule.Name, err)
			}
			if kind == "geosite" || kind == "geoip" {
				if path, ok := c.Categories[kind+":"+value]; !ok || strings.TrimSpace(path) == "" {
					return fmt.Errorf("rule %q: category %s:%s not found in local index or overlays", rule.Name, kind, value)
				}
			}
		}
	}
	return nil
}
