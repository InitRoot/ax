#!/bin/bash

# Test script for MicroK8s provider integration with Axiom
# This script validates that all core Axiom functionality works with the MicroK8s provider

AXIOM_PATH="$HOME/.axiom"
source "$AXIOM_PATH/interact/includes/vars.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TEST_INSTANCE="test-microk8s-$$"

echo -e "${GREEN}=== MicroK8s Provider Test Suite ===${NC}"
echo "Testing instance: $TEST_INSTANCE"
echo

# Function to run test and report result
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3"
    
    echo -n "Testing $test_name... "
    
    if eval "$test_command" >/dev/null 2>&1; then
        if [ "$expected_result" = "success" ]; then
            echo -e "${GREEN}PASS${NC}"
            ((TESTS_PASSED++))
            return 0
        else
            echo -e "${RED}FAIL (expected failure but got success)${NC}"
            ((TESTS_FAILED++))
            return 1
        fi
    else
        if [ "$expected_result" = "failure" ]; then
            echo -e "${GREEN}PASS (expected failure)${NC}"
            ((TESTS_PASSED++))
            return 0
        else
            echo -e "${RED}FAIL${NC}"
            ((TESTS_FAILED++))
            return 1
        fi
    fi
}

# Function to check if provider functions exist
check_provider_functions() {
    echo -e "${YELLOW}Checking provider functions...${NC}"
    
    local functions=(
        "create_instance"
        "delete_instance"
        "instances"
        "instance_ip"
        "instance_list"
        "generate_sshconfig"
        "query_instances"
        "get_image_id"
        "poweron"
        "poweroff"
        "reboot"
        "sizes_list"
    )
    
    source "$AXIOM_PATH/providers/microk8s-functions.sh"
    
    for func in "${functions[@]}"; do
        if declare -f "$func" >/dev/null; then
            echo -e "  ${GREEN}✓${NC} $func"
        else
            echo -e "  ${RED}✗${NC} $func"
            ((TESTS_FAILED++))
        fi
    done
    echo
}

# Function to check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check microk8s
    if command -v microk8s >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} microk8s installed"
        if microk8s status --wait-ready --timeout 10 >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} microk8s running"
        else
            echo -e "  ${RED}✗${NC} microk8s not ready"
            return 1
        fi
    else
        echo -e "  ${RED}✗${NC} microk8s not installed"
        return 1
    fi
    
    # Check kubectl
    if command -v kubectl >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} kubectl available"
    else
        echo -e "  ${RED}✗${NC} kubectl not available"
        return 1
    fi
    
    # Check docker
    if command -v docker >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} docker installed"
        if docker ps >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} docker accessible"
        else
            echo -e "  ${RED}✗${NC} docker not accessible (try: sudo usermod -aG docker $USER)"
            return 1
        fi
    else
        echo -e "  ${RED}✗${NC} docker not installed"
        return 1
    fi
    
    echo
    return 0
}

# Function to test provider setup
test_provider_setup() {
    echo -e "${YELLOW}Testing provider setup...${NC}"
    
    # Check if provider file exists
    run_test "provider functions file" "test -f '$AXIOM_PATH/providers/microk8s-functions.sh'" "success"
    
    # Check if account helper exists
    run_test "account helper script" "test -f '$AXIOM_PATH/interact/account-helpers/microk8s.sh'" "success"
    
    # Check if builder configs exist
    run_test "JSON builder config" "test -f '$AXIOM_PATH/images/json/builders/microk8s.json'" "success"
    run_test "HCL builder config" "test -f '$AXIOM_PATH/images/pkr.hcl/builders/microk8s.pkr.hcl'" "success"
    
    echo
}

# Function to test basic provider functions
test_provider_functions() {
    echo -e "${YELLOW}Testing provider functions...${NC}"
    
    # Source the provider functions
    source "$AXIOM_PATH/providers/microk8s-functions.sh"
    
    # Test sizes_list
    run_test "sizes_list function" "sizes_list | grep -q 'medium'" "success"
    
    # Test regions function
    run_test "regions function" "regions | grep -q '.'" "success"
    
    # Test get_snapshots
    run_test "get_snapshots function" "get_snapshots >/dev/null" "success"
    
    echo
}

# Function to test instance lifecycle (requires microk8s to be running)
test_instance_lifecycle() {
    echo -e "${YELLOW}Testing instance lifecycle...${NC}"
    
    # Skip if no base image available
    if ! docker image inspect axiom-base:latest >/dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠${NC} Skipping instance tests - no base image found"
        echo "    Run the account helper to create a base image first"
        return 0
    fi
    
    # Source provider functions
    source "$AXIOM_PATH/providers/microk8s-functions.sh"
    
    # Test instance creation
    echo -n "Testing instance creation... "
    if create_instance "$TEST_INSTANCE" "axiom-base:latest" "small" "axiom" "" "10" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
        
        # Wait a bit for pod to be ready
        sleep 10
        
        # Test instance listing
        run_test "instance listing" "instances | jq -r '.[].name' | grep -q '$TEST_INSTANCE'" "success"
        
        # Test instance IP
        run_test "instance IP retrieval" "instance_ip '$TEST_INSTANCE' | grep -q '127.0.0.1'" "success"
        
        # Test SSH config generation
        run_test "SSH config generation" "generate_sshconfig" "success"
        
        # Clean up
        echo -n "Cleaning up test instance... "
        if delete_instance "$TEST_INSTANCE" "true" >/dev/null 2>&1; then
            echo -e "${GREEN}PASS${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}FAIL${NC}"
            ((TESTS_FAILED++))
        fi
    else
        echo -e "${RED}FAIL${NC}"
        ((TESTS_FAILED++))
        echo "  Instance creation failed - check microk8s status and base image"
    fi
    
    echo
}

# Function to test axiom command integration
test_axiom_integration() {
    echo -e "${YELLOW}Testing Axiom command integration...${NC}"
    
    # Check if axiom commands can load the provider
    if [ -f "$AXIOM_PATH/interact/includes/functions.sh" ]; then
        # Check if functions.sh links to microk8s provider
        if [ -L "$AXIOM_PATH/interact/includes/functions.sh" ]; then
            local link_target=$(readlink "$AXIOM_PATH/interact/includes/functions.sh")
            if [[ "$link_target" == *"microk8s-functions.sh" ]]; then
                echo -e "  ${GREEN}✓${NC} Provider linked correctly"
                ((TESTS_PASSED++))
            else
                echo -e "  ${RED}✗${NC} Provider not linked (current: $link_target)"
                ((TESTS_FAILED++))
            fi
        else
            echo -e "  ${YELLOW}⚠${NC} functions.sh is not a symlink"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} functions.sh not found"
    fi
    
    echo
}

# Main test execution
main() {
    echo "Starting MicroK8s provider tests..."
    echo
    
    # Check prerequisites first
    if ! check_prerequisites; then
        echo -e "${RED}Prerequisites not met. Please install and configure microk8s, kubectl, and docker.${NC}"
        exit 1
    fi
    
    # Run tests
    check_provider_functions
    test_provider_setup
    test_provider_functions
    test_instance_lifecycle
    test_axiom_integration
    
    # Summary
    echo -e "${YELLOW}=== Test Summary ===${NC}"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed! MicroK8s provider is ready to use.${NC}"
        echo
        echo "Next steps:"
        echo "1. Run: axiom-provider microk8s"
        echo "2. Run: axiom-account microk8s"
        echo "3. Test with: axiom-init --run"
        exit 0
    else
        echo -e "${RED}Some tests failed. Please check the issues above.${NC}"
        exit 1
    fi
}

# Run main function
main "$@"