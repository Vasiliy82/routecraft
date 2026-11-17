// Package geodata discovers category metadata without downloading rule sets.
package geodata

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"

	"github.com/vasiliy82/routecraft/internal/policy"
)

const DefaultTreesURL = "https://api.github.com/repos/MetaCubeX/meta-rules-dat/git/trees/"
const sourceName = "MetaCubeX/meta-rules-dat:sing"

type Catalog struct {
	Version    int        `json:"version"`
	Source     string     `json:"source"`
	Revision   string     `json:"revision"`
	Categories []Category `json:"categories"`
}

// GitBlob is the upstream Git object SHA-1, not a file SHA-256 checksum.
type Category struct {
	Kind         string `json:"kind"`
	Name         string `json:"name"`
	UpstreamPath string `json:"upstream_path"`
	GitBlob      string `json:"git_blob_sha1"`
	Size         int64  `json:"size"`
}

type tree struct {
	SHA       string     `json:"sha"`
	Truncated bool       `json:"truncated"`
	Entries   []treeItem `json:"tree"`
}

type treeItem struct {
	Path string `json:"path"`
	Type string `json:"type"`
	SHA  string `json:"sha"`
	Size int64  `json:"size"`
}

var shaPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)

// Discover reads four individual Git trees. GitHub may truncate a recursive
// tree for this upstream, so any truncated response is treated as an error.
func Discover(ctx context.Context, client *http.Client, treesURL string) (Catalog, error) {
	var result Catalog
	if client == nil {
		return result, fmt.Errorf("HTTP client is required")
	}
	base, err := url.Parse(treesURL)
	if err != nil || (base.Scheme != "https" && base.Scheme != "http") || base.Host == "" || !strings.HasSuffix(base.Path, "/") || base.RawQuery != "" || base.Fragment != "" {
		return result, fmt.Errorf("invalid trees URL")
	}
	fetch := func(ref string) (tree, error) {
		var t tree
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, treesURL+url.PathEscape(ref), nil)
		if err != nil {
			return t, err
		}
		request.Header.Set("Accept", "application/vnd.github+json")
		request.Header.Set("User-Agent", "routecraft")
		response, err := client.Do(request)
		if err != nil {
			return t, fmt.Errorf("get tree %s: %w", ref, err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return t, fmt.Errorf("get tree %s: HTTP %d", ref, response.StatusCode)
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, 8*1024*1024+1))
		if err != nil {
			return t, err
		}
		if len(body) > 8*1024*1024 {
			return t, fmt.Errorf("tree %s exceeds size limit", ref)
		}
		if err = json.Unmarshal(body, &t); err != nil {
			return t, fmt.Errorf("decode tree %s: %w", ref, err)
		}
		if t.Truncated || !shaPattern.MatchString(t.SHA) {
			return t, fmt.Errorf("tree %s is truncated or has invalid revision", ref)
		}
		if ref != "sing" && t.SHA != ref {
			return t, fmt.Errorf("tree %s returned a different revision", ref)
		}
		return t, nil
	}
	findTree := func(t tree, name string) (string, error) {
		for _, item := range t.Entries {
			if item.Path == name && item.Type == "tree" && shaPattern.MatchString(item.SHA) {
				return item.SHA, nil
			}
		}
		return "", fmt.Errorf("required tree %q not found", name)
	}
	root, err := fetch("sing")
	if err != nil {
		return result, err
	}
	geoRef, err := findTree(root, "geo")
	if err != nil {
		return result, err
	}
	geo, err := fetch(geoRef)
	if err != nil {
		return result, err
	}
	result = Catalog{Version: 1, Source: sourceName, Revision: root.SHA, Categories: []Category{}}
	for _, kind := range []string{"geoip", "geosite"} {
		ref, err := findTree(geo, kind)
		if err != nil {
			return Catalog{}, err
		}
		categoryTree, err := fetch(ref)
		if err != nil {
			return Catalog{}, err
		}
		count := 0
		seen := make(map[string]bool)
		for _, item := range categoryTree.Entries {
			if item.Type != "blob" || !strings.HasSuffix(item.Path, ".srs") {
				continue
			}
			name := strings.TrimSuffix(item.Path, ".srs")
			if _, _, err := policy.SplitFilter(kind + ":" + name); err != nil || !shaPattern.MatchString(item.SHA) || item.Size <= 0 || seen[name] {
				return Catalog{}, fmt.Errorf("invalid or duplicate %s category %q", kind, name)
			}
			seen[name] = true
			result.Categories = append(result.Categories, Category{Kind: kind, Name: name, UpstreamPath: "geo/" + kind + "/" + item.Path, GitBlob: item.SHA, Size: item.Size})
			count++
		}
		if count == 0 {
			return Catalog{}, fmt.Errorf("no %s categories found", kind)
		}
	}
	sort.Slice(result.Categories, func(i, j int) bool {
		if result.Categories[i].Kind != result.Categories[j].Kind {
			return result.Categories[i].Kind < result.Categories[j].Kind
		}
		return result.Categories[i].Name < result.Categories[j].Name
	})
	return result, nil
}
