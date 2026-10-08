package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
)

func testObjectBudget(t *testing.T, upload, download, requests int64) *objectBudget {
	t.Helper()
	identifier := token()
	b, err := validatedObjectBudget(&objectBudgetConfig{ID: identifier[:8] + "-" + identifier[8:12] + "-" + identifier[12:16] + "-" + identifier[16:20] + "-" + identifier[20:], MaxUploadBytes: upload, MaxDownloadBytes: download, MaxRequests: requests})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func budgetedCloudflareFixture(t *testing.T, budget *objectBudget, handler cloudflareTestTransport) *cloudflareStorage {
	t.Helper()
	s := cloudflareFixture(t, handler)
	s.setBudget(budget)
	s.client.Transport = handler
	return s
}

func TestObjectBudgetInvalidConfigRejectedBeforeMetadataReservation(t *testing.T) {
	database := filepath.Join(t.TempDir(), "metadata.db")
	encoded, _ := json.Marshal(map[string]any{
		"metadataURL":          "sqlite3://" + database,
		"createCloudflareTest": true,
		"s3BucketURL":          "https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/r2/buckets/fixture-bucket",
		"cloudflareToken":      "fixture-bearer",
		"objectBudget":         map[string]any{"id": "b26d904c-599d-4ac7-9e91-e8615a379b40", "maxRequests": 200, "maxUploadBytes": 0, "maxDownloadBytes": 128 << 20},
	})
	var configuration config
	if err := json.Unmarshal(encoded, &configuration); err != nil {
		t.Fatal(err)
	}
	e, err := connect(configuration)
	if e != nil {
		_ = e.fs.Close()
	}
	if !errors.Is(err, syscall.EINVAL) {
		t.Fatal("invalid budget was accepted")
	}
	if _, err := os.Stat(database); !os.IsNotExist(err) {
		t.Fatal("invalid budget reserved metadata")
	}
}

func TestObjectBudgetChargesFailedRequestsAndRefusesDispatchAtLimit(t *testing.T) {
	budget := testObjectBudget(t, 100, 3*(maxCloudflareObject+1), 2)
	calls := 0
	s := budgetedCloudflareFixture(t, budget, func(r *http.Request) (*http.Response, error) {
		calls++
		return cloudflareReply(500, []byte("bad")), nil
	})
	var downloaded atomic.Int64
	s.downloaded = &downloaded
	for i := 0; i < 2; i++ {
		if _, err := s.Get(context.Background(), "volume/chunk", 0, 1); !errors.Is(err, syscall.EIO) {
			t.Fatal("provider failure not redacted")
		}
	}
	if _, err := s.Get(context.Background(), "volume/chunk", 0, 1); !errors.Is(err, syscall.EDQUOT) {
		t.Fatal("request ceiling not enforced")
	}
	if calls != 2 || budget.snapshot().Requests != 2 || budget.snapshot().DownloadBytes != 6 || budget.snapshot().DownloadReservedBytes != 2*(maxCloudflareObject+1) || downloaded.Load() != 6 {
		t.Fatal("failed request accounting differs")
	}
}

func TestObjectBudgetReservesEveryUploadAttemptWithoutRefund(t *testing.T) {
	budget := testObjectBudget(t, 8, 3*65537, 10)
	calls := 0
	s := budgetedCloudflareFixture(t, budget, func(r *http.Request) (*http.Response, error) {
		calls++
		if r.GetBody != nil {
			t.Fatal("automatic request replay remained enabled")
		}
		_, _ = io.ReadAll(r.Body)
		return nil, io.ErrUnexpectedEOF
	})
	for i := 0; i < 2; i++ {
		if err := s.Put(context.Background(), "volume/chunk", strings.NewReader("data")); !errors.Is(err, syscall.EIO) {
			t.Fatal("failed upload was acknowledged")
		}
	}
	if err := s.Put(context.Background(), "volume/chunk", strings.NewReader("x")); !errors.Is(err, syscall.EDQUOT) {
		t.Fatal("upload ceiling not enforced")
	}
	if calls != 2 || budget.snapshot().UploadBytes != 8 || budget.snapshot().Requests != 2 || budget.snapshot().DownloadReservedBytes != 2*65537 {
		t.Fatal("upload reservation was refunded")
	}
}

func TestObjectBudgetConcurrentUploadCannotExceedReservations(t *testing.T) {
	budget := testObjectBudget(t, 64, 100*65537, 100)
	var calls, uploaded atomic.Int64
	s := budgetedCloudflareFixture(t, budget, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		data, _ := io.ReadAll(r.Body)
		uploaded.Add(int64(len(data)))
		return cloudflareReply(204, nil), nil
	})
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := s.Put(context.Background(), "volume/chunk", strings.NewReader("12345678"))
			if err != nil && !errors.Is(err, syscall.EDQUOT) {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if calls.Load() != 8 || uploaded.Load() != 64 || budget.snapshot().UploadBytes != 64 {
		t.Fatal("concurrent upload exceeded budget")
	}
}

func TestObjectBudgetConcurrentUnknownLengthDownloadsStopAtReservationLimit(t *testing.T) {
	budget := testObjectBudget(t, 100, 3*(maxCloudflareObject+1), 200)
	var calls, downloaded atomic.Int64
	s := budgetedCloudflareFixture(t, budget, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		response := cloudflareReply(200, bytes.Repeat([]byte{1}, 16))
		response.ContentLength = -1
		return response, nil
	})
	s.downloaded = &downloaded
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body, err := s.Get(context.Background(), "volume/chunk", 0, 16)
			if body != nil {
				_ = body.Close()
			}
			if err != nil && !errors.Is(err, syscall.EDQUOT) {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	before := calls.Load()
	if _, err := s.Get(context.Background(), "volume/chunk", 0, 1); !errors.Is(err, syscall.EDQUOT) {
		t.Fatal("depleted download dispatched another request")
	}
	if downloaded.Load() != 48 || budget.snapshot().DownloadBytes != 48 || budget.snapshot().DownloadReservedBytes != 3*(maxCloudflareObject+1) || before != 3 || calls.Load() != before {
		t.Fatal("concurrent download exceeded limit")
	}
}

func TestObjectBudgetCountsMutationsAndExactLengthDownload(t *testing.T) {
	budget := testObjectBudget(t, 10, (maxCloudflareObject+1)+65537, 5)
	s := budgetedCloudflareFixture(t, budget, func(r *http.Request) (*http.Response, error) {
		if r.Method == http.MethodPut {
			return cloudflareReply(200, []byte(`{"success":true}`)), nil
		}
		return cloudflareReply(200, []byte("tail")), nil
	})
	if err := s.Put(context.Background(), "volume/chunk", strings.NewReader("x")); err != nil {
		t.Fatal(err)
	}
	body, err := s.Get(context.Background(), "volume/chunk", 0, 4)
	if err != nil {
		t.Fatal(err)
	}
	_ = body.Close()
	if budget.snapshot().DownloadBytes != 20 || budget.snapshot().DownloadReservedBytes != (maxCloudflareObject+1)+65537 {
		t.Fatal("mutation response was omitted from budget")
	}
	if _, err := s.Get(context.Background(), "volume/chunk", 0, 1); !errors.Is(err, syscall.EDQUOT) {
		t.Fatal("exact download boundary not enforced")
	}
}

func TestObjectBudgetHandlesReopenAndImmutableLimits(t *testing.T) {
	budget := testObjectBudget(t, 100, 100, 3)
	c := config{MetadataURL: "sqlite3://" + filepath.Join(t.TempDir(), "metadata.db"), CreateCloudflareTest: true,
		S3BucketURL:     "https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/r2/buckets/fixture-bucket",
		CloudflareToken: "fixture-bearer", ObjectBudget: &budget.config}
	e, err := connect(c)
	if err != nil {
		t.Fatal(err)
	}
	if got := e.objectBudget.snapshot(); got == nil || *got != (objectBudgetMetrics{}) {
		t.Fatal("missing initial zero budget metrics")
	}
	if err := e.objectBudget.reserveRequest(4, 10); err != nil {
		t.Fatal(err)
	}
	_ = e.fs.Close()
	c.CreateCloudflareTest = false
	reopened, err := connect(c)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.fs.Close()
	if got := reopened.objectBudget.snapshot(); got.Requests != 1 || got.UploadBytes != 4 || got.DownloadReservedBytes != 10 {
		t.Fatal("reopening reset budget")
	}
	changed := *c.ObjectBudget
	changed.MaxRequests++
	c.ObjectBudget = &changed
	if other, err := connect(c); !errors.Is(err, syscall.EINVAL) {
		if other != nil {
			_ = other.fs.Close()
		}
		t.Fatal("existing budget limits could be changed")
	}
}

func TestObjectBudgetTransportDisablesUnaccountedReplays(t *testing.T) {
	s := cloudflareFixture(t, nil)
	s.setBudget(testObjectBudget(t, 10, 10, 1))
	transport, ok := s.client.Transport.(*http.Transport)
	if !ok || !transport.DisableKeepAlives || !transport.DisableCompression || transport.ForceAttemptHTTP2 || transport.TLSNextProto == nil {
		t.Fatal("budgeted transport permits uncounted retry or decompression")
	}
}

func TestObjectBudgetReservesResponseCapacityBeforeConcurrentDispatch(t *testing.T) {
	budget := testObjectBudget(t, 1000, 2*(maxCloudflareObject+1), 200)
	var calls atomic.Int64
	s := budgetedCloudflareFixture(t, budget, func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return cloudflareReply(200, []byte("x")), nil
	})
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body, err := s.Get(context.Background(), "volume/chunk", 0, 1)
			if body != nil {
				_ = body.Close()
			}
			if err != nil && !errors.Is(err, syscall.EDQUOT) {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if calls.Load() != 2 {
		t.Fatalf("response capacity failed to bound dispatch: got %d requests, want 2", calls.Load())
	}
	if budget.snapshot().DownloadReservedBytes != 2*(maxCloudflareObject+1) || budget.snapshot().DownloadBytes != 2 {
		t.Fatal("reserved capacity was refunded or confused with actual bytes")
	}
}

func TestObjectBudgetResponseReaderCannotExceedOwnReservation(t *testing.T) {
	for _, length := range []int64{-1, 5} {
		budget := testObjectBudget(t, 100, 100, 10)
		if err := budget.reserveRequest(0, 5); err != nil {
			t.Fatal(err)
		}
		body := &budgetResponseBody{ReadCloser: io.NopCloser(strings.NewReader("123456")), budget: budget, remaining: length, allowanceLeft: 5}
		data, err := io.ReadAll(body)
		if length == -1 && !errors.Is(err, syscall.EDQUOT) {
			t.Fatal("unknown-length response exceeded its reservation")
		}
		if length == 5 && err != nil {
			t.Fatal("exact-length response at reservation boundary failed")
		}
		if string(data) != "12345" || budget.snapshot().DownloadBytes != 5 || budget.snapshot().DownloadReservedBytes != 5 {
			t.Fatal("reader consumed beyond its reservation")
		}
	}
}
