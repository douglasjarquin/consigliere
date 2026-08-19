package main

import (
	"bufio"
	"os/exec"
	"strconv"
	"strings"
)

// childrenByParent returns a snapshot of every process's parent pid, from a
// single `ps` invocation, mapping each parent pid to its direct child pids.
func childrenByParent() (map[int][]int, error) {
	out, err := exec.Command("ps", "-axo", "pid=,ppid=").Output()
	if err != nil {
		return nil, err
	}

	children := make(map[int][]int)
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 2 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		if err1 != nil || err2 != nil {
			continue
		}
		children[ppid] = append(children[ppid], pid)
	}
	return children, scanner.Err()
}

// descendantsOf returns every transitive descendant of root from a single
// process-table snapshot -- including a descendant that has escaped root's
// own process group (e.g. by calling setsid()), which a pgid-scoped signal
// can never reach. A single snapshot means a process spawned after it was
// taken cannot appear; that is an acceptable bound on a defense-in-depth
// sweep run after the group-scoped termination has already had its full
// timeout budget to reach the same processes.
func descendantsOf(root int) ([]int, error) {
	byParent, err := childrenByParent()
	if err != nil {
		return nil, err
	}

	var descendants []int
	seen := map[int]bool{root: true}
	queue := []int{root}
	for len(queue) > 0 {
		pid := queue[0]
		queue = queue[1:]
		for _, child := range byParent[pid] {
			if seen[child] {
				continue
			}
			seen[child] = true
			descendants = append(descendants, child)
			queue = append(queue, child)
		}
	}
	return descendants, nil
}
