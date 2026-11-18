package tailscalestatus

import "testing"

func TestCandidatesRequireRunningOnlineApprovedAndAddress(t *testing.T) {
	data := []byte(`{"BackendState":"Running","Peer":{"a":{"HostName":"online","Online":true,"ExitNodeOption":true,"ExitNode":true,"TailscaleIPs":["fd00::1","100.64.0.2"]},"b":{"Online":false,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.3"]},"c":{"Online":true,"ExitNodeOption":false,"TailscaleIPs":["100.64.0.4"]},"d":{"Online":true,"ExitNodeOption":true,"TailscaleIPs":["fd00::5"]}}}`)
	got, err := Candidates(data)
	if err != nil || len(got) != 2 || got[0].Name != "online" || got[0].Address != "100.64.0.2" || !got[0].Selected || got[1].Address != "fd00::5" {
		t.Fatalf("got %+v, %v", got, err)
	}
}

func TestCandidatesRejectStoppedOrMalformedStatus(t *testing.T) {
	for _, data := range []string{`{"BackendState":"Stopped"}`, `{broken`} {
		if _, err := Candidates([]byte(data)); err == nil {
			t.Fatalf("accepted %q", data)
		}
	}
}

func TestSelectRejectsUnavailableOrAmbiguousAddress(t *testing.T) {
	status := []byte(`{"BackendState":"Running","Peer":{"a":{"Online":true,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.2"]},"b":{"Online":false,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.3"]}}}`)
	if _, err := Select(status, "100.64.0.2"); err != nil {
		t.Fatal(err)
	}
	if _, err := Select(status, "100.64.0.3"); err == nil {
		t.Fatal("accepted offline peer")
	}
	ambiguous := []byte(`{"BackendState":"Running","Peer":{"a":{"Online":true,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.2"]},"b":{"Online":true,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.2"]}}}`)
	if _, err := Select(ambiguous, "100.64.0.2"); err == nil {
		t.Fatal("accepted ambiguous address")
	}
}
