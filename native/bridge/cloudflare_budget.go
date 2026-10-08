package main

import (
	"io"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
)

// These optional payload limits belong to one explicitly named smoke run. The
// registry deliberately retains counters across handle closure for the lifetime
// of this process: reopening the drive cannot reset a run's limits.
type objectBudgetConfig struct {
	ID               string `json:"id"`
	MaxUploadBytes   int64  `json:"maxUploadBytes"`
	MaxDownloadBytes int64  `json:"maxDownloadBytes"`
	MaxRequests      int64  `json:"maxRequests"`
}

type objectBudgetMetrics struct {
	Requests              int64 `json:"requests"`
	UploadBytes           int64 `json:"uploadBytes"`
	DownloadBytes         int64 `json:"downloadBytes"`
	DownloadReservedBytes int64 `json:"downloadReservedBytes"`
}

type objectBudget struct {
	sync.Mutex
	config objectBudgetConfig
	used   objectBudgetMetrics
}

var objectBudgets = struct {
	sync.Mutex
	values map[string]*objectBudget
}{values: make(map[string]*objectBudget)}

func validatedObjectBudget(c *objectBudgetConfig) (*objectBudget, error) {
	if c == nil {
		return nil, nil
	}
	value := *c
	value.ID = strings.ToLower(value.ID)
	if !regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`).MatchString(value.ID) || value.MaxRequests <= 0 || value.MaxUploadBytes <= 0 || value.MaxDownloadBytes <= 0 {
		return nil, syscall.EINVAL
	}
	objectBudgets.Lock()
	defer objectBudgets.Unlock()
	if existing := objectBudgets.values[value.ID]; existing != nil {
		if existing.config != value {
			return nil, syscall.EINVAL
		}
		return existing, nil
	}
	// A bounded registry also makes accidental unbounded budget creation fail
	// closed. No API removes entries or resets counters during a running process.
	if len(objectBudgets.values) >= 128 {
		return nil, syscall.ENOSPC
	}
	budget := &objectBudget{config: value}
	objectBudgets.values[value.ID] = budget
	return budget, nil
}

func (b *objectBudget) reserveRequest(uploadBytes, responseBytes int64) error {
	if b == nil {
		return nil
	}
	b.Lock()
	defer b.Unlock()
	if uploadBytes < 0 || responseBytes <= 0 || b.used.Requests >= b.config.MaxRequests || uploadBytes > b.config.MaxUploadBytes-b.used.UploadBytes || responseBytes > b.config.MaxDownloadBytes-b.used.DownloadReservedBytes {
		return syscall.EDQUOT
	}
	b.used.Requests++
	// Failed and partially sent requests consume the whole reservation. Retrying
	// never refunds bytes and can therefore never exceed the upload ceiling.
	b.used.UploadBytes += uploadBytes
	// Reserve the maximum response body before dispatch, independently of how
	// much this attempt eventually consumes. In-flight requests and retries may
	// not reuse capacity reserved by another response, even after it closes.
	b.used.DownloadReservedBytes += responseBytes
	return nil
}

func (b *objectBudget) snapshot() *objectBudgetMetrics {
	if b == nil {
		return nil
	}
	b.Lock()
	defer b.Unlock()
	value := b.used
	return &value
}

type budgetResponseBody struct {
	io.ReadCloser
	budget        *objectBudget
	downloaded    *atomic.Int64
	remaining     int64 // HTTP Content-Length; -1 means unknown.
	allowanceLeft int64
}

func (r *budgetResponseBody) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if r.remaining == 0 {
		return 0, io.EOF
	}
	// Serialize individual reads across every handle sharing this budget. The
	// reservation is checked before the underlying reader sees the buffer, so
	// simultaneous downloads cannot overrun the remaining response-body limit.
	r.budget.Lock()
	defer r.budget.Unlock()
	available := r.budget.config.MaxDownloadBytes - r.budget.used.DownloadBytes
	if r.allowanceLeft < available {
		available = r.allowanceLeft
	}
	if available <= 0 {
		return 0, syscall.EDQUOT
	}
	if int64(len(p)) > available {
		p = p[:available]
	}
	if r.remaining > 0 && int64(len(p)) > r.remaining {
		p = p[:r.remaining]
	}
	n, err := r.ReadCloser.Read(p)
	r.budget.used.DownloadBytes += int64(n)
	r.allowanceLeft -= int64(n)
	if r.downloaded != nil {
		r.downloaded.Add(int64(n))
	}
	if r.remaining > 0 {
		r.remaining -= int64(n)
	}
	return n, err
}
