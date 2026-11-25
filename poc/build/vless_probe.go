package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"time"
)

// The encoded DNS query requests an A record for example.com. Verify the
// response header because sing-box tools fetch also prints HTTP error bodies.
const vlessDNSProbeURL = "https://1.1.1.1/dns-query?dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"

func selectVLESSNode(dataDir, bootstrap string, nodes []map[string]any, tags []string) (string, error) {
	config, err := os.CreateTemp(dataDir, ".vless-probe.*.json")
	if err != nil {
		return "", err
	}
	defer os.Remove(config.Name())
	err = json.NewEncoder(config).Encode(map[string]any{
		"outbounds": nodes,
		"dns": map[string]any{
			"servers": []map[string]any{{"type": "udp", "tag": "local-dns", "server": bootstrap}},
		},
		"route": map[string]any{"default_domain_resolver": "local-dns"},
	})
	closeErr := config.Close()
	if err != nil {
		return "", err
	}
	if closeErr != nil {
		return "", closeErr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	for _, tag := range tags {
		if ctx.Err() != nil {
			break
		}
		probeCtx, stop := context.WithTimeout(ctx, 4*time.Second)
		result, err := exec.CommandContext(probeCtx, "sing-box", "tools", "fetch", "-c", config.Name(), "-o", tag, vlessDNSProbeURL).Output()
		stop()
		if err == nil && len(result) >= 12 && binary.BigEndian.Uint16(result[:2]) == 0 &&
			result[2]&0x80 != 0 && result[3]&0x0f == 0 && binary.BigEndian.Uint16(result[6:8]) > 0 {
			return tag, nil
		}
	}
	return "", fmt.Errorf("no VLESS subscription node answered the DNS over HTTPS probe")
}
