-include .env

VYPER_PATH := $(CURDIR)/.venv-vyper037-py39/bin
FORGE := PATH="$(VYPER_PATH):$$PATH" forge

# deps
update:; $(FORGE) update
build  :; $(FORGE) build
size  :; $(FORGE) build --sizes

# storage inspection
inspect :; $(FORGE) inspect ${contract} storage-layout --pretty

# specify which fork to use. set this in our .env
# if we want to test multiple forks in one go, remove this as an argument below
FORK_URL := ${ETH_RPC_URL} # BASE_RPC_URL, ETH_RPC_URL, ARBITRUM_RPC_URL

# if we want to run only matching tests, set that here
test := test_

# local tests without fork
test  :; $(FORGE) test -vv --fork-url ${FORK_URL} --ffi
trace  :; $(FORGE) test -vvv --fork-url ${FORK_URL} --ffi
gas  :; $(FORGE) test --fork-url ${FORK_URL} --gas-report --ffi
test-contract  :; $(FORGE) test -vv --match-contract $(contract) --fork-url ${FORK_URL} --ffi
test-contract-gas  :; $(FORGE) test --gas-report --match-contract ${contract} --fork-url ${FORK_URL} --ffi
trace-contract  :; $(FORGE) test -vvv --match-contract $(contract) --fork-url ${FORK_URL} --ffi
test-test  :; $(FORGE) test -vv --match-test $(test) --fork-url ${FORK_URL} --ffi
test-test-trace  :; $(FORGE) test -vvv --match-test $(test) --fork-url ${FORK_URL} --ffi
trace-test  :; $(FORGE) test -vvvvv --match-test $(test) --fork-url ${FORK_URL} --ffi
snapshot :; $(FORGE) snapshot -vv --fork-url ${FORK_URL} --ffi
snapshot-diff :; $(FORGE) snapshot --diff -vv --fork-url ${FORK_URL} --ffi
trace-setup  :; $(FORGE) test -vvvv --fork-url ${FORK_URL} --ffi
trace-max  :; $(FORGE) test -vvvvv --fork-url ${FORK_URL} --ffi
coverage :; $(FORGE) coverage --fork-url ${FORK_URL} --ffi
coverage-report :; $(FORGE) coverage --report lcov --fork-url ${FORK_URL} --ffi
coverage-debug :; $(FORGE) coverage --report debug --fork-url ${FORK_URL} --ffi

coverage-html:
	@echo "Running coverage..."
	$(FORGE) coverage --report lcov --fork-url ${FORK_URL} --ffi
	@if [ "`uname`" = "Darwin" ]; then \
		lcov --ignore-errors inconsistent --remove lcov.info 'src/test/**' --output-file lcov.info; \
		genhtml --ignore-errors inconsistent -o coverage-report lcov.info; \
	else \
		lcov --remove lcov.info 'src/test/**' --output-file lcov.info; \
		genhtml -o coverage-report lcov.info; \
	fi
	@echo "Coverage report generated at coverage-report/index.html"

clean  :; $(FORGE) clean
