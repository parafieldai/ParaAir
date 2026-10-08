package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"syscall"
	"testing"
)

type cloudflareTestTransport func(*http.Request) (*http.Response, error)

func (f cloudflareTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func cloudflareFixture(t *testing.T, handler cloudflareTestTransport) *cloudflareStorage {
	t.Helper()
	s, err := newCloudflareStorage("https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/r2/buckets/fixture-bucket", "fixture-bearer")
	if err != nil {
		t.Fatal(err)
	}
	s.client.Transport = handler
	return s
}
func cloudflareReply(status int, body []byte) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(body)), ContentLength: int64(len(body))}
}
func TestCloudflareFullChunkRangeCountsActualDownloadedBody(t *testing.T) {
	payload := bytes.Repeat([]byte("0123456789abcdef"), 4096)
	s := cloudflareFixture(t, func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Authorization") != "Bearer fixture-bearer" || r.Header.Get("Range") != "" || r.Method != "GET" {
			t.Fatal("unexpected authenticated full-object request")
		}
		return cloudflareReply(200, payload), nil
	})
	counted := &countingStorage{ObjectStorage: s, countsDownloadedBody: true}
	s.downloaded = &counted.bytes
	body, err := counted.Get(context.Background(), "volume/chunks/1", 100, 17)
	if err != nil {
		t.Fatal(err)
	}
	defer body.Close()
	got, err := io.ReadAll(body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload[100:117]) {
		t.Fatal("range contents differ")
	}
	if counted.bytes.Load() != int64(len(payload)) || counted.gets.Load() != 1 {
		t.Fatal("full object transfer was not counted exactly once")
	}
}
func TestCloudflareBodyAndRangeLimits(t *testing.T) {
	calls := 0
	s := cloudflareFixture(t, func(r *http.Request) (*http.Response, error) {
		calls++
		response := cloudflareReply(200, bytes.Repeat([]byte{1}, maxCloudflareObject+1))
		response.ContentLength = -1
		return response, nil
	})
	if _, err := s.Get(context.Background(), "volume/chunk", -1, 1); !errors.Is(err, syscall.EINVAL) {
		t.Fatal("negative offset accepted")
	}
	if _, err := s.Get(context.Background(), "volume/chunk", 0, maxCloudflareObject+1); !errors.Is(err, syscall.EINVAL) {
		t.Fatal("excessive range accepted")
	}
	if calls != 0 {
		t.Fatal("invalid range sent a request")
	}
	counted := &countingStorage{ObjectStorage: s, countsDownloadedBody: true}
	s.downloaded = &counted.bytes
	if _, err := counted.Get(context.Background(), "volume/chunk", 0, 10); !errors.Is(err, syscall.EFBIG) {
		t.Fatal("oversized body accepted")
	}
	if counted.bytes.Load() != maxCloudflareObject+1 {
		t.Fatal("oversized body read was not bounded")
	}
	before := calls
	if err := s.Put(context.Background(), "volume/chunk", bytes.NewReader(bytes.Repeat([]byte{1}, maxCloudflareObject+1))); !errors.Is(err, syscall.EFBIG) {
		t.Fatal("oversized upload accepted")
	}
	if calls != before {
		t.Fatal("oversized upload reached transport")
	}
}
func TestCloudflareURLKeysAndCredentialBoundary(t *testing.T) {
	for _, endpoint := range []string{
		"http://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/r2/buckets/fixture-bucket",
		"https://api.cloudflare.com.attacker.invalid/client/v4/accounts/0123456789abcdef0123456789abcdef/r2/buckets/fixture-bucket",
		"https://person:secret@api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/r2/buckets/fixture-bucket",
		"https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/r2/buckets/fixture-bucket?token=secret",
	} {
		if _, err := newCloudflareStorage(endpoint, "fixture-bearer"); !errors.Is(err, syscall.EINVAL) {
			t.Fatal("unsafe API endpoint accepted")
		}
	}
	s := cloudflareFixture(t, func(r *http.Request) (*http.Response, error) { return cloudflareReply(200, []byte("x")), nil })
	for _, key := range []string{"", "../chunk", "volume/../chunk", "volume//chunk", "volume/./chunk", "volume/secret\n"} {
		if _, err := s.objectURL(key); !errors.Is(err, syscall.EINVAL) {
			t.Fatal("unsafe object key accepted")
		}
	}
	encoded, err := s.objectURL("volume/chunk?query#fragment%literal")
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if u.RawQuery != "" || u.Fragment != "" || !strings.HasSuffix(u.EscapedPath(), "volume%2Fchunk%3Fquery%23fragment%25literal") {
		t.Fatal("object name escaped the API path")
	}
	if strings.Contains(s.String(), "fixture-bearer") {
		t.Fatal("storage description leaked bearer")
	}
}
func TestCloudflareStatusErrorsAndRedirectsAreRedacted(t *testing.T) {
	for status, want := range map[int]syscall.Errno{401: syscall.EACCES, 403: syscall.EACCES, 404: syscall.ENOENT, 429: syscall.EAGAIN, 500: syscall.EIO, 302: syscall.EIO} {
		calls := 0
		s := cloudflareFixture(t, func(r *http.Request) (*http.Response, error) {
			calls++
			if r.URL.Host != "api.cloudflare.com" {
				t.Fatal("authorization followed redirect")
			}
			response := cloudflareReply(status, []byte("provider-secret-do-not-log"))
			response.Header.Set("Location", "https://attacker.invalid/")
			return response, nil
		})
		_, err := s.Get(context.Background(), "volume/chunk", 0, 1)
		if !errors.Is(err, want) {
			t.Fatalf("status %d returned wrong errno", status)
		}
		if calls != 1 {
			t.Fatal("error status caused extra request")
		}
		if strings.Contains(err.Error(), "provider-secret") {
			t.Fatal("error exposed provider body")
		}
	}
}
func TestCloudflareMutationAcknowledgmentRequiresValidSuccess(t *testing.T) {
	for _, tc := range []struct {
		status int
		body   string
		valid  bool
	}{
		{200, `{"success":true}`, true}, {204, "", true}, {200, "", false},
		{200, `<html>provider-error</html>`, false}, {200, `{"success":false}`, false}, {200, `{"unrelated":true}`, false},
	} {
		s := cloudflareFixture(t, func(r *http.Request) (*http.Response, error) { return cloudflareReply(tc.status, []byte(tc.body)), nil })
		err := s.Put(context.Background(), "volume/chunk", strings.NewReader("payload"))
		if (err == nil) != tc.valid {
			t.Fatalf("status %d mutation validity differs", tc.status)
		}
	}
}
