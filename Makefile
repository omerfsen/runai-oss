# runai-oss labs. Run `make help` for targets.
#
# CONTEXT picks the cluster: k3d-runai (default) or rke2-runai-cp (VM track).

SHELL := /bin/bash
CONTEXT ?= k3d-runai
export CONTEXT

.PHONY: help labs tests

help:
	@echo "runai-oss (CONTEXT=$(CONTEXT))"
	@echo
	@echo "  make labs    run every lab's check.sh"
	@echo "  make tests   run the platform tests below Run:ai"

labs:
	labs/run.sh

tests:
	tests/run.sh
