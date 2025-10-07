# MongoDB Hardening Utility - Tests

Simple test framework for the MongoDB Hardening Utility.

## Quick Start

```bash
# Run all tests
./test-runner.sh

# From project root
make test
```

## Test Coverage

- ✅ File structure validation
- ✅ Shell script syntax checking
- ✅ Library loading verification
- ✅ Basic functionality tests

## Requirements

- Bash 4.0+
- Standard Unix tools (find, grep, etc.)

## Adding Tests

Edit `test-runner.sh` and add new test functions following the existing pattern.

Tests should be:
- Fast and lightweight
- Independent of external services  
- Easy to understand and maintain