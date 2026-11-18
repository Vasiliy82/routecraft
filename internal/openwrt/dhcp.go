package openwrt

import (
	"encoding/json"
	"fmt"
	"sort"
)

// DHCPSection describes one UCI DHCP section. Several sections may point to
// the same logical interface; treating one of them as authoritative is unsafe.
type DHCPSection struct {
	Name      string `json:"name"`
	Interface string `json:"interface"`
	Anonymous bool   `json:"anonymous"`
}

// DHCPSections reads a UCI JSON dump obtained from ubus uci get. It returns
// every DHCP section referencing logicalInterface, including sections whose
// interface defaults to their own name. No changes are made to UCI.
func DHCPSections(data []byte, logicalInterface string) ([]DHCPSection, error) {
	if !logicalName.MatchString(logicalInterface) {
		return nil, fmt.Errorf("invalid logical interface name")
	}
	var dump struct {
		Values map[string]struct {
			Type      string `json:".type"`
			Name      string `json:".name"`
			Anonymous bool   `json:".anonymous"`
			Interface string `json:"interface"`
		} `json:"values"`
	}
	if err := json.Unmarshal(data, &dump); err != nil {
		return nil, fmt.Errorf("invalid DHCP UCI status: %w", err)
	}
	if dump.Values == nil {
		return nil, fmt.Errorf("DHCP UCI sections are missing")
	}
	result := make([]DHCPSection, 0)
	for key, section := range dump.Values {
		if section.Type != "dhcp" {
			continue
		}
		name := section.Name
		if name == "" {
			name = key
		}
		if !logicalName.MatchString(name) {
			return nil, fmt.Errorf("invalid DHCP section name")
		}
		iface := section.Interface
		if iface == "" {
			iface = name
		}
		if iface == logicalInterface {
			result = append(result, DHCPSection{Name: name, Interface: iface, Anonymous: section.Anonymous})
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}
