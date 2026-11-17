package geodata

import (
	"context"
	"crypto/sha1"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestFetchChecksPinnedContent(t *testing.T) {
	data := []byte("test SRS bytes")
	blob := sha1.Sum(append([]byte(fmt.Sprintf("blob %d\x00", len(data))), data...))
	catalog := Catalog{Version: 1, Source: sourceName, Revision: rootSHA, Categories: []Category{{Kind: "geosite", Name: "acer@cn", UpstreamPath: "geo/geosite/acer@cn.srs", GitBlob: fmt.Sprintf("%x", blob), Size: int64(len(data))}}}
	client := &http.Client{Transport: fakeTransport(func(req *http.Request) (*http.Response, error) {
		if !strings.Contains(req.URL.Path, rootSHA+"/geo/geosite/acer@cn.srs") {
			t.Errorf("unexpected URL: %s", req.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(data))), Header: make(http.Header)}, nil
	})}
	got, err := Fetch(context.Background(), client, catalog, "geosite", "acer@cn")
	if err != nil || string(got.Data) != string(data) || len(got.SHA256) != 64 {
		t.Fatalf("got %+v, %v", got, err)
	}
	catalog.Categories[0].GitBlob = rootSHA
	if _, err = Fetch(context.Background(), client, catalog, "geosite", "acer@cn"); err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("got %v", err)
	}
	if _, err = Fetch(context.Background(), client, catalog, "geosite", "missing"); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("got %v", err)
	}
}
