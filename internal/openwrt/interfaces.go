// Package openwrt reads OpenWrt runtime information without changing it.
package openwrt

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"regexp"
	"sort"
)

var logicalName = regexp.MustCompile(`^[a-zA-Z0-9_]+$`)

type LogicalInterface struct {
	Name     string   `json:"name"`
	Device   string   `json:"device"`
	L3Device string   `json:"l3_device"`
	Up       bool     `json:"up"`
	Dynamic  bool     `json:"dynamic"`
	IPv4     []string `json:"ipv4"`
	IPv6     []string `json:"ipv6"`
}

// InterfacesForDevice reads the result of `ubus call network.interface dump`.
// A device can belong to several logical interfaces; callers must not assume
// that the first entry is the DHCP section or silently choose among them.
func InterfacesForDevice(data []byte, device string) ([]LogicalInterface, error) {
	if device == "" {
		return nil, fmt.Errorf("device is required")
	}
	// The ubus key for a logical interface name is also "interface".
	var raw struct {
		Interfaces []struct {
			Name     string `json:"interface"`
			Device   string `json:"device"`
			L3Device string `json:"l3_device"`
			Up       bool   `json:"up"`
			Dynamic  bool   `json:"dynamic"`
			IPv4     []struct {
				Address string `json:"address"`
				Mask    int    `json:"mask"`
			} `json:"ipv4-address"`
			IPv6 []struct {
				Address string `json:"address"`
				Mask    int    `json:"mask"`
			} `json:"ipv6-address"`
		} `json:"interface"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("invalid network interface status: %w", err)
	}
	if raw.Interfaces == nil {
		return nil, fmt.Errorf("network interface list is missing")
	}
	result := make([]LogicalInterface, 0)
	for _, item := range raw.Interfaces {
		if item.Device != device && item.L3Device != device {
			continue
		}
		if !logicalName.MatchString(item.Name) {
			return nil, fmt.Errorf("invalid logical interface name")
		}
		iface := LogicalInterface{Name: item.Name, Device: item.Device, L3Device: item.L3Device, Up: item.Up, Dynamic: item.Dynamic}
		for _, entry := range item.IPv4 {
			addr, err := netip.ParseAddr(entry.Address)
			if err != nil || !addr.Is4() || entry.Mask < 0 || entry.Mask > 32 {
				return nil, fmt.Errorf("invalid IPv4 interface address")
			}
			iface.IPv4 = append(iface.IPv4, netip.PrefixFrom(addr, entry.Mask).String())
		}
		for _, entry := range item.IPv6 {
			addr, err := netip.ParseAddr(entry.Address)
			if err != nil || !addr.Is6() || addr.Is4In6() || addr.Zone() != "" || entry.Mask < 0 || entry.Mask > 128 {
				return nil, fmt.Errorf("invalid IPv6 interface address")
			}
			iface.IPv6 = append(iface.IPv6, netip.PrefixFrom(addr, entry.Mask).String())
		}
		result = append(result, iface)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}
