package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/juicedata/juicefs/pkg/object"
)

// OAuth R2 uses the documented Cloudflare REST API. It reads a bounded complete
// JuiceFS chunk; this deliberately makes no unverified HTTP Range claim.
type cloudflareStorage struct {
	object.DefaultObjectStorage
	base       *url.URL
	bearer     string
	client     *http.Client
	downloaded *atomic.Int64
	budget     *objectBudget
}

const maxCloudflareObject = 8 << 20

func validCloudflareBucketURL(value string) bool {
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" || u.Host != "api.cloudflare.com" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" || u.ForceQuery {
		return false
	}
	return regexp.MustCompile(`^/client/v4/accounts/[a-f0-9]{32}/r2/buckets/[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`).MatchString(u.Path) && !strings.Contains(u.Path, "..")
}

func newCloudflareStorage(endpoint, bearer string) (*cloudflareStorage, error) {
	if !validCloudflareBucketURL(endpoint) || bearer == "" || len(bearer) > 32768 || strings.ContainsAny(bearer, "\r\n\x00") {
		return nil, syscall.EINVAL
	}
	base, _ := url.Parse(endpoint)
	return &cloudflareStorage{base: base, bearer: bearer, client: &http.Client{
		Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}
func (s *cloudflareStorage) setBudget(budget *objectBudget) {
	s.budget = budget
	// Go can transparently retry an idempotent request on a reused connection.
	// Budgeted runs use fresh HTTP/1.1 connections, preventing unaccounted
	// transport retries beneath the one reservation per dispatched request.
	s.client.Transport = &http.Transport{
		Proxy: http.ProxyFromEnvironment, DisableKeepAlives: true, DisableCompression: true,
		TLSHandshakeTimeout: 10 * time.Second, MaxResponseHeaderBytes: 64 << 10,
		TLSNextProto: make(map[string]func(string, *tls.Conn) http.RoundTripper),
	}
}
func (s *cloudflareStorage) String() string {
	return "cloudflare-oauth://" + s.base.Path[strings.LastIndex(s.base.Path, "/")+1:] + "/"
}
func (s *cloudflareStorage) Create(context.Context) error { return syscall.ENOTSUP }
func (s *cloudflareStorage) objectURL(key string) (string, error) {
	if key == "" || len(key) > 4096 || strings.ContainsAny(key, "\r\n\x00") {
		return "", syscall.EINVAL
	}
	for _, part := range strings.Split(key, "/") {
		if part == ".." || part == "." || part == "" {
			return "", syscall.EINVAL
		}
	}
	u := *s.base
	u.Path += "/objects/" + key
	u.RawPath = s.base.EscapedPath() + "/objects/" + url.PathEscape(key)
	return u.String(), nil
}
func (s *cloudflareStorage) call(ctx context.Context, method, key string, body io.Reader) (*http.Response, error) {
	target, err := s.objectURL(key)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, method, target, body)
	if err != nil {
		return nil, syscall.EINVAL
	}
	req.Header.Set("Authorization", "Bearer "+s.bearer)
	if method == http.MethodPut {
		req.Header.Set("Content-Type", "application/octet-stream")
	}
	responseReservation := int64(65537)
	if method == http.MethodGet {
		responseReservation = maxCloudflareObject + 1
	}
	if s.budget != nil {
		if req.ContentLength < 0 || (req.Body != nil && req.Body != http.NoBody && req.ContentLength == 0) {
			return nil, syscall.EINVAL
		}
		if err := s.budget.reserveRequest(req.ContentLength, responseReservation); err != nil {
			return nil, err
		}
		req.GetBody = nil
	}
	response, err := s.client.Do(req)
	if err != nil {
		return nil, syscall.EIO
	}
	if s.budget != nil {
		response.Body = &budgetResponseBody{ReadCloser: response.Body, budget: s.budget, downloaded: s.downloaded, remaining: response.ContentLength, allowanceLeft: responseReservation}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		defer response.Body.Close()
		if s.budget != nil {
			// Count bounded provider-error payloads, including each retry, without
			// retaining or exposing their potentially sensitive contents.
			if _, err := io.Copy(io.Discard, io.LimitReader(response.Body, 65536)); err != nil {
				if errors.Is(err, syscall.EDQUOT) {
					return nil, syscall.EDQUOT
				}
				return nil, syscall.EIO
			}
		}
		switch response.StatusCode {
		case 404:
			return nil, syscall.ENOENT
		case 401, 403:
			return nil, syscall.EACCES
		case 429:
			return nil, syscall.EAGAIN
		default:
			return nil, syscall.EIO
		}
	}
	return response, nil
}
func (s *cloudflareStorage) Get(ctx context.Context, key string, off, limit int64, getters ...object.AttrGetter) (io.ReadCloser, error) {
	if off < 0 || off > maxCloudflareObject || limit > maxCloudflareObject {
		return nil, syscall.EINVAL
	}
	r, err := s.call(ctx, http.MethodGet, key, nil)
	if err != nil {
		return nil, err
	}
	defer r.Body.Close()
	if r.ContentLength > maxCloudflareObject {
		return nil, syscall.EFBIG
	}
	var reader io.Reader = r.Body
	if s.downloaded != nil && s.budget == nil {
		reader = &countingReader{ReadCloser: r.Body, bytes: s.downloaded}
	}
	data, err := io.ReadAll(io.LimitReader(reader, maxCloudflareObject+1))
	if err != nil {
		if errors.Is(err, syscall.EDQUOT) {
			return nil, syscall.EDQUOT
		}
		return nil, syscall.EIO
	}
	if len(data) > maxCloudflareObject {
		return nil, syscall.EFBIG
	}
	if off > int64(len(data)) {
		return nil, syscall.EINVAL
	}
	end := int64(len(data))
	if limit >= 0 && limit < end-off {
		end = off + limit
	}
	return io.NopCloser(bytes.NewReader(data[off:end])), nil
}
func (s *cloudflareStorage) Put(ctx context.Context, key string, in io.Reader, getters ...object.AttrGetter) error {
	data, err := io.ReadAll(io.LimitReader(in, maxCloudflareObject+1))
	if err != nil {
		return syscall.EIO
	}
	if len(data) > maxCloudflareObject {
		return syscall.EFBIG
	}
	r, err := s.call(ctx, http.MethodPut, key, bytes.NewReader(data))
	if err != nil {
		return err
	}
	return cloudflareMutationResult(r)
}
func (s *cloudflareStorage) Delete(ctx context.Context, key string, getters ...object.AttrGetter) error {
	r, err := s.call(ctx, http.MethodDelete, key, nil)
	if err == syscall.ENOENT {
		return nil
	}
	if err != nil {
		return err
	}
	return cloudflareMutationResult(r)
}
func cloudflareMutationResult(r *http.Response) error {
	defer r.Body.Close()
	data, err := io.ReadAll(io.LimitReader(r.Body, 65537))
	if errors.Is(err, syscall.EDQUOT) {
		return syscall.EDQUOT
	}
	if err != nil || len(data) > 65536 {
		return syscall.EIO
	}
	if len(data) == 0 && r.StatusCode == http.StatusNoContent {
		return nil
	}
	var envelope struct {
		Success *bool `json:"success"`
	}
	if json.Unmarshal(data, &envelope) != nil || envelope.Success == nil || !*envelope.Success {
		return syscall.EIO
	}
	return nil
}
