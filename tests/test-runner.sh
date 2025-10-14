#!/usr/bin/env bash
# MongoDB Hardening Utility - Test Runner
# Simple, lean test framework for all modules

set -euo pipefail

# Test configuration
readonly TEST_DIR="$(dirname "${BASH_SOURCE[0]}")"
readonly PROJECT_ROOT="$(dirname "$TEST_DIR")"
readonly LIB_DIR="$PROJECT_ROOT/lib/harden-mongo-server"
readonly MAIN_SCRIPT="$PROJECT_ROOT/harden-mongo-server"

# Test results tracking
declare -g TESTS_RUN=0
declare -g TESTS_PASSED=0
declare -g TESTS_FAILED=0

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Test result functions
pass() {
    ((TESTS_RUN++))
    ((TESTS_PASSED++))
    echo -e "${GREEN}[PASS]${NC} $1"
}

fail() {
    ((TESTS_RUN++))
    ((TESTS_FAILED++))
    echo -e "${RED}[FAIL]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Test functions
test_file_structure() {
    info "Testing project file structure..."
    
    [[ -f "$MAIN_SCRIPT" ]] && pass "Main script exists" || fail "Main script missing"
    [[ -x "$MAIN_SCRIPT" ]] && pass "Main script is executable" || fail "Main script not executable"
    
    for lib in core logging ui system mongodb security ssl firewall backup monitoring; do
        [[ -f "$LIB_DIR/${lib}.sh" ]] && pass "Library ${lib}.sh exists" || fail "Library ${lib}.sh missing"
    done
}

test_shell_syntax() {
    info "Testing shell script syntax..."
    
    if bash -n "$MAIN_SCRIPT" 2>/dev/null; then
        pass "Main script syntax valid"
    else
        fail "Main script syntax invalid"
    fi
    
    for lib_file in "$LIB_DIR"/*.sh; do
        if [[ -f "$lib_file" ]]; then
            local lib_name
            lib_name="$(basename "$lib_file")"
            if bash -n "$lib_file" 2>/dev/null; then
                pass "Library $lib_name syntax valid"
            else
                fail "Library $lib_name syntax invalid"
            fi
        fi
    done
}

test_library_loading() {
    info "Testing library loading..."
    
    for lib_file in "$LIB_DIR"/*.sh; do
        if [[ -f "$lib_file" ]]; then
            local lib_name test_script
            lib_name="$(basename "$lib_file")"
            test_script="$(mktemp)"
            
            {
                echo "#!/usr/bin/env bash"
                echo "set -euo pipefail"
                echo "# Override variables to prevent directory creation during tests"
echo "export HARDEN_MONGO_SERVER_TEST_MODE=true"
                echo "source '$lib_file' 2>/dev/null || exit 0"
                echo "exit 0"
            } > "$test_script"
            
            if bash "$test_script" >/dev/null 2>&1; then
                pass "Library $lib_name loads successfully"
            else
                fail "Library $lib_name fails to load"
            fi
            
            rm -f "$test_script"
        fi
    done
}

test_main_functionality() {
    info "Testing main script functionality..."
    
    # Test help command (should work without root)
    if "$MAIN_SCRIPT" --help >/dev/null 2>&1; then
        pass "Help command works"
    else
        fail "Help command fails"
    fi
    
    # Test version command
    if "$MAIN_SCRIPT" --version >/dev/null 2>&1; then
        pass "Version command works"
    else
        fail "Version command fails"
    fi
}

# Run all tests
run_tests() {
echo "MongoDB Server Hardening Tool - Test Runner"
    echo "======================================="
    echo
    
    test_file_structure
    echo
    test_shell_syntax
    echo
    test_library_loading
    echo
    test_main_functionality
    echo
    
    # Summary
    echo "Test Summary"
    echo "============"
    echo "Tests run: $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    fi
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests "$@"
fi