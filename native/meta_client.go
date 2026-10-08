// StreamDrive embedding adapter. Compiled beside the pinned JuiceFS package.
// NewClient in upstream exits the whole process on configuration errors. A
// native macOS extension needs an error instead. This wrapper uses the exact
// registered constructors and Config validation from that pinned package.
package meta

import (
	"fmt"
	"strings"
)

func NewStreamDriveClient(uri string, conf *Config) (Meta, error) {
	driver, address, ok := strings.Cut(uri, "://")
	if !ok || address == "" {
		return nil, fmt.Errorf("invalid metadata URL")
	}
	constructor, ok := metaDrivers[driver]
	if !ok {
		return nil, fmt.Errorf("unsupported metadata driver")
	}
	// Credential-bearing environment variables must not override a profile's
	// explicit Keychain-resolved URL inside a multi-profile app process.
	if conf == nil {
		conf = DefaultConf()
	} else {
		conf.SelfCheck()
	}
	client, err := constructor(driver, address, conf)
	if err != nil {
		return nil, fmt.Errorf("metadata client initialization failed")
	}
	return client, nil
}
