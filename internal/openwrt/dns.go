package openwrt

import (
	"encoding/json"
	"fmt"
	"sort"
)

// DNSInstance contains dnsmasq settings relevant to determining whether it can
// serve a LAN. Other settings, including local names and upstreams, are not
// changed by this inspection.
type DNSInstance struct {
	Name               string   `json:"name"`
	Anonymous          bool     `json:"anonymous"`
	Port               string   `json:"port"`
	Interfaces         []string `json:"interfaces"`
	ExcludedInterfaces []string `json:"excluded_interfaces"`
	ListenAddresses    []string `json:"listen_addresses"`
	LocalService       string   `json:"localservice"`
}

type stringList []string

func (s *stringList) UnmarshalJSON(data []byte) error {
	var list []string
	if err := json.Unmarshal(data, &list); err == nil {
		*s = list
		return nil
	}
	var single string
	if err := json.Unmarshal(data, &single); err != nil {
		return fmt.Errorf("expected a string or list of strings")
	}
	*s = []string{single}
	return nil
}

// DNSInstances reads all dnsmasq sections from a UCI RPC dump without picking
// an instance on the caller's behalf.
func DNSInstances(data []byte) ([]DNSInstance, error) {
	var dump struct {
		Values map[string]struct {
			Type         string     `json:".type"`
			Name         string     `json:".name"`
			Anonymous    bool       `json:".anonymous"`
			Port         string     `json:"port"`
			Interfaces   stringList `json:"interface"`
			Excluded     stringList `json:"notinterface"`
			Listen       stringList `json:"listen_address"`
			LocalService string     `json:"localservice"`
		} `json:"values"`
	}
	if err := json.Unmarshal(data, &dump); err != nil {
		return nil, fmt.Errorf("invalid DNS UCI status: %w", err)
	}
	if dump.Values == nil {
		return nil, fmt.Errorf("DNS UCI sections are missing")
	}
	result := make([]DNSInstance, 0)
	for key, section := range dump.Values {
		if section.Type != "dnsmasq" {
			continue
		}
		name := section.Name
		if name == "" {
			name = key
		}
		if !logicalName.MatchString(name) {
			return nil, fmt.Errorf("invalid dnsmasq section name")
		}
		result = append(result, DNSInstance{Name: name, Anonymous: section.Anonymous, Port: section.Port, Interfaces: section.Interfaces, ExcludedInterfaces: section.Excluded, ListenAddresses: section.Listen, LocalService: section.LocalService})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}
