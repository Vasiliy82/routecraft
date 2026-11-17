package geodata

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

const (
	rootSHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	geoSHA  = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	ipSHA   = "cccccccccccccccccccccccccccccccccccccccc"
	siteSHA = "dddddddddddddddddddddddddddddddddddddddd"
	blobSHA = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
)

type fakeTransport func(*http.Request) (*http.Response, error)

func (f fakeTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func catalogClient(t *testing.T, truncated bool) *http.Client {
	t.Helper()
	trees := map[string]tree{
		"sing":  {SHA: rootSHA, Entries: []treeItem{{Path: "geo", Type: "tree", SHA: geoSHA}}},
		geoSHA:  {SHA: geoSHA, Entries: []treeItem{{Path: "geoip", Type: "tree", SHA: ipSHA}, {Path: "geosite", Type: "tree", SHA: siteSHA}}},
		ipSHA:   {SHA: ipSHA, Entries: []treeItem{{Path: "telegram.srs", Type: "blob", SHA: blobSHA, Size: 99}}},
		siteSHA: {SHA: siteSHA, Truncated: truncated, Entries: []treeItem{{Path: "airchina@!cn.srs", Type: "blob", SHA: blobSHA, Size: 42}, {Path: "openai.srs", Type: "blob", SHA: blobSHA, Size: 10}}},
	}
	return &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		tr, ok := trees[strings.TrimPrefix(r.URL.Path, "/trees/")]
		if !ok {
			return &http.Response{StatusCode: 404, Body: io.NopCloser(strings.NewReader("missing")), Header: make(http.Header)}, nil
		}
		data, err := json.Marshal(tr)
		if err != nil {
			t.Fatal(err)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(data))), Header: make(http.Header)}, nil
	})}
}

func TestDiscoverListsCompleteCatalog(t *testing.T) {
	catalog, err := Discover(context.Background(), catalogClient(t, false), "https://fixture.invalid/trees/")
	if err != nil {
		t.Fatal(err)
	}
	if catalog.Revision != rootSHA || len(catalog.Categories) != 3 {
		t.Fatalf("unexpected catalog: %+v", catalog)
	}
	if got := catalog.Categories[1]; got.Kind != "geosite" || got.Name != "airchina@!cn" || got.Size != 42 || got.GitBlob != blobSHA {
		t.Fatalf("unexpected source metadata: %+v", got)
	}
}

func TestDiscoverRefusesTruncatedOrMissingTrees(t *testing.T) {
	client := catalogClient(t, true)
	_, err := Discover(context.Background(), client, "https://fixture.invalid/trees/")
	if err == nil || !strings.Contains(err.Error(), "truncated") {
		t.Fatalf("got %v", err)
	}
	_, err = Discover(context.Background(), client, "https://fixture.invalid/missing/")
	if err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("got %v", err)
	}
}

func TestDiscoverRefusesRevisionMismatch(t *testing.T) {
	client := &http.Client{Transport: fakeTransport(func(r *http.Request) (*http.Response, error) {
		tr := tree{SHA: rootSHA}
		if strings.HasSuffix(r.URL.Path, "/sing") {
			tr.Entries = []treeItem{{Path: "geo", Type: "tree", SHA: geoSHA}}
		}
		data, _ := json.Marshal(tr)
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(data))), Header: make(http.Header)}, nil
	})}
	if _, err := Discover(context.Background(), client, "https://fixture.invalid/"); err == nil || !strings.Contains(err.Error(), "different revision") {
		t.Fatalf("got %v", err)
	}
}
