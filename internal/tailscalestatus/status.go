// Package tailscalestatus extracts usable exit-node candidates from local status.
package tailscalestatus

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"sort"
)

type Candidate struct {
	Name     string `json:"name"`
	Address  string `json:"address"`
	Selected bool   `json:"selected"`
}

// Candidates reports online, approved exit nodes from a running client. This
// is discovery only: it does not prove that a separate identity has access.
func Candidates(data []byte) ([]Candidate, error) {
	var status struct {
		BackendState string
		Peer         map[string]struct {
			HostName       string
			DNSName        string
			TailscaleIPs   []string
			Online         bool
			ExitNodeOption bool
			ExitNode       bool
		}
	}
	if err := json.Unmarshal(data, &status); err != nil {
		return nil, fmt.Errorf("invalid Tailscale status: %w", err)
	}
	if status.BackendState != "Running" {
		return nil, fmt.Errorf("Tailscale client is not running")
	}
	result := make([]Candidate, 0)
	for _, peer := range status.Peer {
		if !peer.Online || !peer.ExitNodeOption {
			continue
		}
		name := peer.DNSName
		if name == "" {
			name = peer.HostName
		}
		var selected netip.Addr
		for _, raw := range peer.TailscaleIPs {
			addr, err := netip.ParseAddr(raw)
			if err != nil || addr.Zone() != "" || addr.IsUnspecified() || addr.IsMulticast() {
				continue
			}
			if !selected.IsValid() || addr.Is4() {
				selected = addr
			}
			if addr.Is4() {
				break
			}
		}
		if selected.IsValid() {
			result = append(result, Candidate{Name: name, Address: selected.String(), Selected: peer.ExitNode})
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Address < result[j].Address })
	return result, nil
}

// Select checks an explicit address against the supplied status snapshot.
// Callers must obtain a new snapshot when validating an interactive choice.
func Select(data []byte, address string) (Candidate, error) {
	want, err := netip.ParseAddr(address)
	if err != nil || want.Zone() != "" {
		return Candidate{}, fmt.Errorf("invalid exit-node address")
	}
	nodes, err := Candidates(data)
	if err != nil {
		return Candidate{}, err
	}
	var selected Candidate
	found := false
	for _, node := range nodes {
		if node.Address != want.String() {
			continue
		}
		if found {
			return Candidate{}, fmt.Errorf("ambiguous exit-node address")
		}
		selected, found = node, true
	}
	if !found {
		return Candidate{}, fmt.Errorf("exit node is not an online approved candidate")
	}
	return selected, nil
}
