package jj

import (
	"fmt"
	"os/exec"
	"strings"
)

// ListTrackedFiles returns the paths tracked at the current revision.
func ListTrackedFiles() ([]string, error) {
	out, err := exec.Command("jj", "file", "list", "-r", "@").Output()
	if err != nil {
		return nil, fmt.Errorf("jj file list: %w", err)
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	paths := make([]string, 0, len(lines))
	for _, l := range lines {
		if l == "" {
			continue
		}
		paths = append(paths, l)
	}
	return paths, nil
}
