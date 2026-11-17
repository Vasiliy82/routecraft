package geodata

import (
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/vasiliy82/routecraft/internal/policy"
)

const maxRuleSetSize = 64 * 1024 * 1024

type Download struct {
	Data   []byte
	SHA256 string
}

// Fetch downloads exactly one indexed SRS from the pinned source revision.
// Git blob SHA-1 includes a header and must not be confused with file SHA-256.
func Fetch(ctx context.Context, client *http.Client, catalog Catalog, kind, name string) (Download, error) {
	var result Download
	if client == nil || catalog.Version != 1 || catalog.Source != sourceName || !shaPattern.MatchString(catalog.Revision) {
		return result, fmt.Errorf("invalid source catalog")
	}
	if kind != "geosite" && kind != "geoip" {
		return result, fmt.Errorf("invalid category type %q", kind)
	}
	if _, _, err := policy.SplitFilter(kind + ":" + name); err != nil {
		return result, err
	}
	var selected *Category
	for i := range catalog.Categories {
		entry := &catalog.Categories[i]
		if entry.Kind == kind && entry.Name == name {
			if selected != nil {
				return result, fmt.Errorf("duplicate category %s:%s", kind, name)
			}
			selected = entry
		}
	}
	if selected == nil {
		return result, fmt.Errorf("category %s:%s not found in index", kind, name)
	}
	expectedPath := "geo/" + kind + "/" + name + ".srs"
	if selected.UpstreamPath != expectedPath || !shaPattern.MatchString(selected.GitBlob) || selected.Size <= 0 || selected.Size > maxRuleSetSize {
		return result, fmt.Errorf("invalid source metadata for %s:%s", kind, name)
	}
	pathParts := []string{"geo", kind, name + ".srs"}
	for i := range pathParts {
		pathParts[i] = url.PathEscape(pathParts[i])
	}
	address := "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/" + catalog.Revision + "/" + strings.Join(pathParts, "/")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return result, err
	}
	req.Header.Set("User-Agent", "routecraft")
	resp, err := client.Do(req)
	if err != nil {
		return result, fmt.Errorf("download %s:%s: %w", kind, name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return result, fmt.Errorf("download %s:%s: HTTP %d", kind, name, resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, selected.Size+1))
	if err != nil {
		return result, err
	}
	if int64(len(data)) != selected.Size {
		return result, fmt.Errorf("download %s:%s: size mismatch", kind, name)
	}
	blob := sha1.New()
	fmt.Fprintf(blob, "blob %d\x00", len(data))
	_, _ = blob.Write(data)
	if hex.EncodeToString(blob.Sum(nil)) != selected.GitBlob {
		return result, fmt.Errorf("download %s:%s: Git blob checksum mismatch", kind, name)
	}
	sum := sha256.Sum256(data)
	return Download{Data: data, SHA256: hex.EncodeToString(sum[:])}, nil
}
