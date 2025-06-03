#!/bin/bash

# Sysbench Comprehensive Benchmark Script
# This script runs CPU and PostgreSQL benchmarks using sysbench

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get instance type for filename
get_instance_type() {
    local instance_type="unknown"
    if command -v ec2-metadata >/dev/null 2>&1; then
        instance_type=$(ec2-metadata --instance-type 2>/dev/null | cut -d: -f2 | xargs | tr '[:upper:]' '[:lower:]' || echo "unknown")
    elif command -v curl >/dev/null 2>&1; then
        # Alternative method using EC2 metadata service
        instance_type=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
    fi
    echo "$instance_type"
}

# Results file with instance type in filename
INSTANCE_TYPE=$(get_instance_type)
RESULTS_FILE="sysbench_results_${INSTANCE_TYPE}_$(date +%Y%m%d_%H%M%S).txt"

# Initialize results file
init_results_file() {
    # Get instance type (works on AWS EC2)
    local instance_type="Unknown"
    if command -v ec2-metadata >/dev/null 2>&1; then
        instance_type=$(ec2-metadata --instance-type 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
    elif command -v curl >/dev/null 2>&1; then
        # Alternative method using EC2 metadata service
        instance_type=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "Unknown")
    fi
    
    {
        echo "====================================================================="
        echo "SYSBENCH COMPREHENSIVE BENCHMARK RESULTS"  
        echo "====================================================================="
        echo "Start Time: $(date)"
        echo "Hostname: $(hostname)"
        echo "Instance Type: $instance_type"
        echo "Operating System: $(uname -a)"
        echo "CPU Info: $(lscpu | grep "Model name" | cut -d: -f2 | xargs)"
        echo "CPU Cores: $(nproc --all)"
        echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
        echo "====================================================================="
        echo ""
    } > "$RESULTS_FILE"
}

# Logging function with file output
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${BLUE}${message}${NC}"
    echo "$message" >> "$RESULTS_FILE"
}

error() {
    local message="[ERROR] $1"
    echo -e "${RED}${message}${NC}" >&2
    echo "$message" >> "$RESULTS_FILE"
}

success() {
    local message="[SUCCESS] $1"
    echo -e "${GREEN}${message}${NC}"
    echo "$message" >> "$RESULTS_FILE"
}

warning() {
    local message="[WARNING] $1"
    echo -e "${YELLOW}${message}${NC}"
    echo "$message" >> "$RESULTS_FILE"
}

# Function to write section header to results file
write_section_header() {
    {
        echo ""
        echo "====================================================================="
        echo "$1"
        echo "====================================================================="
        echo ""
    } >> "$RESULTS_FILE"
}

# Check if sysbench is installed
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v sysbench &> /dev/null; then
        error "sysbench is not installed. Please install it first."
        exit 1
    fi
    
    if ! command -v psql &> /dev/null; then
        error "PostgreSQL client (psql) is not installed."
        exit 1
    fi
    
    if ! command -v k6 &> /dev/null; then
        warning "k6 is not installed. K6 tests will be skipped."
        K6_AVAILABLE=false
    else
        K6_AVAILABLE=true
        log "k6 found - K6 tests will be included"
    fi
    
    success "Prerequisites check passed"
}

# Setup PostgreSQL database and user
setup_postgresql() {
    log "Setting up PostgreSQL database and user..."
    
    # Set postgres user password
    sudo -i -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'password';" || {
        error "Failed to set postgres password"
        exit 1
    }
    
    # Create sbtest database if it doesn't exist
    sudo -i -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname='sbtest';" | grep -q 1 || {
        sudo -i -u postgres psql -c "CREATE DATABASE sbtest;"
    }
    
    # Create sbtest user if it doesn't exist
    sudo -i -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='sbtest';" | grep -q 1 || {
        sudo -i -u postgres psql -c "CREATE USER sbtest WITH PASSWORD 'password';"
    }
    
    # Grant privileges
    sudo -i -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE sbtest TO sbtest;"
    
    success "PostgreSQL setup completed"
}

# Run CPU benchmarks
run_cpu_benchmarks() {
    log "Starting CPU benchmarks..."
    
    cores=$(nproc --all)
    log "Detected $cores CPU cores"
    
    write_section_header "SINGLE-CORE CPU BENCHMARK (10 minutes)"
    log "Running single-core CPU benchmark (10 minutes)..."
    sysbench cpu --cpu-max-prime=2000 --threads=1 --time=600 --report-interval=10 run 2>&1 | tee -a "$RESULTS_FILE"
    success "Single-core CPU benchmark completed"
    
    write_section_header "MULTI-CORE CPU BENCHMARK (10 minutes)"
    log "Running multi-core CPU benchmark (10 minutes)..."
    sysbench cpu --cpu-max-prime=2000 --threads=$cores --time=600 --report-interval=10 run 2>&1 | tee -a "$RESULTS_FILE"
    success "Multi-core CPU benchmark completed"
}

# Clean up existing PostgreSQL test data
cleanup_postgresql() {
    log "Cleaning up PostgreSQL test data..."
    write_section_header "POSTGRESQL CLEANUP"
    sudo sysbench oltp_update_index \
        --tables=10 \
        --table-size=1000000 \
        --pgsql-host=127.0.0.1 \
        --pgsql-user=sbtest \
        --pgsql-password=password \
        --pgsql-db=sbtest \
        cleanup 2>&1 | tee -a "$RESULTS_FILE" || warning "Cleanup failed (may not exist yet)"
    success "PostgreSQL cleanup completed"
}

# Prepare PostgreSQL test data
prepare_postgresql() {
    log "Preparing PostgreSQL test data..."
    write_section_header "POSTGRESQL DATA PREPARATION"
    sudo sysbench oltp_read_write \
        --tables=10 \
        --table-size=1000000 \
        --pgsql-host=127.0.0.1 \
        --pgsql-user=sbtest \
        --pgsql-password=password \
        --pgsql-db=sbtest \
        prepare 2>&1 | tee -a "$RESULTS_FILE"
    success "PostgreSQL test data preparation completed"
}

# Run PostgreSQL benchmarks
run_postgresql_benchmarks() {
    log "Starting PostgreSQL benchmarks..."
    
    cores=$(nproc --all)
    
    write_section_header "READ-ONLY BENCHMARK (2 minutes)"
    log "Running Read-Only benchmark (2 minutes)..."
    sudo sysbench oltp_read_only \
        --tables=10 \
        --table-size=1000000 \
        --threads=$cores \
        --time=120 \
        --report-interval=10 \
        --pgsql-host=127.0.0.1 \
        --pgsql-user=sbtest \
        --pgsql-password=password \
        --pgsql-db=sbtest \
        run 2>&1 | tee -a "$RESULTS_FILE"
    success "Read-Only benchmark completed"
    
    write_section_header "WRITE-ONLY BENCHMARK (2 minutes)"
    log "Running Write-Only benchmark (2 minutes)..."
    sudo sysbench oltp_write_only \
        --tables=10 \
        --table-size=1000000 \
        --threads=$cores \
        --time=120 \
        --report-interval=10 \
        --pgsql-host=127.0.0.1 \
        --pgsql-user=sbtest \
        --pgsql-password=password \
        --pgsql-db=sbtest \
        run 2>&1 | tee -a "$RESULTS_FILE"
    success "Write-Only benchmark completed"
    
    write_section_header "READ-WRITE BENCHMARK (2 minutes)"
    log "Running Read-Write benchmark (2 minutes)..."
    sudo sysbench oltp_read_write \
        --tables=10 \
        --table-size=1000000 \
        --threads=$cores \
        --time=120 \
        --report-interval=10 \
        --pgsql-host=127.0.0.1 \
        --pgsql-user=sbtest \
        --pgsql-password=password \
        --pgsql-db=sbtest \
        run 2>&1 | tee -a "$RESULTS_FILE"
    success "Read-Write benchmark completed"
    
    write_section_header "OLTP POINT SELECT BENCHMARK"
    log "Running OLTP Point Select benchmark..."
    sudo sysbench oltp_point_select \
        --tables=10 \
        --table-size=1000000 \
        --threads=$cores \
        --pgsql-host=127.0.0.1 \
        --pgsql-user=sbtest \
        --pgsql-password=password \
        --pgsql-db=sbtest \
        run 2>&1 | tee -a "$RESULTS_FILE"
    success "OLTP Point Select benchmark completed"
    
    write_section_header "OLTP UPDATE INDEX BENCHMARK"
    log "Running OLTP Update Index benchmark..."
    sudo sysbench oltp_update_index \
        --tables=10 \
        --table-size=1000000 \
        --threads=$cores \
        --pgsql-host=127.0.0.1 \
        --pgsql-user=sbtest \
        --pgsql-password=password \
        --pgsql-db=sbtest \
        run 2>&1 | tee -a "$RESULTS_FILE"
    success "OLTP Update Index benchmark completed"
}

# Run K6 benchmarks
run_k6_benchmarks() {
    if [[ "$K6_AVAILABLE" != true ]]; then
        log "Skipping K6 benchmarks - k6 not installed"
        return 0
    fi
    
    log "Starting K6 benchmarks..."
    
    # Check if k6 test files exist
    local k6_base_path="./k6"
    
    if [[ ! -d "$k6_base_path" ]]; then
        warning "K6 test directory not found at $k6_base_path - skipping K6 tests"
        return 0
    fi
    
    # AOT Tests
    if [[ -f "$k6_base_path/aot/insert-test.js" ]]; then
        write_section_header "K6 AOT INSERT TEST"
        log "Running K6 AOT Insert test..."
        k6 run "$k6_base_path/aot/insert-test.js" 2>&1 | tee -a "$RESULTS_FILE"
        success "K6 AOT Insert test completed"
    else
        warning "K6 AOT Insert test not found at $k6_base_path/aot/insert-test.js"
    fi
    
    if [[ -f "$k6_base_path/aot/query-test.js" ]]; then
        write_section_header "K6 AOT QUERY TEST"
        log "Running K6 AOT Query test..."
        k6 run "$k6_base_path/aot/query-test.js" 2>&1 | tee -a "$RESULTS_FILE"
        success "K6 AOT Query test completed"
    else
        warning "K6 AOT Query test not found at $k6_base_path/aot/query-test.js"
    fi
    
    # NAOT Tests
    if [[ -f "$k6_base_path/naot/insert-test.js" ]]; then
        write_section_header "K6 NAOT INSERT TEST"
        log "Running K6 NAOT Insert test..."
        k6 run "$k6_base_path/naot/insert-test.js" 2>&1 | tee -a "$RESULTS_FILE"
        success "K6 NAOT Insert test completed"
    else
        warning "K6 NAOT Insert test not found at $k6_base_path/naot/insert-test.js"
    fi
    
    if [[ -f "$k6_base_path/naot/query-test.js" ]]; then
        write_section_header "K6 NAOT QUERY TEST"
        log "Running K6 NAOT Query test..."
        k6 run "$k6_base_path/naot/query-test.js" 2>&1 | tee -a "$RESULTS_FILE"
        success "K6 NAOT Query test completed"
    else
        warning "K6 NAOT Query test not found at $k6_base_path/naot/query-test.js"
    fi
    
    success "All available K6 benchmarks completed"
}

# Run final CPU benchmark
run_final_cpu_benchmark() {
    write_section_header "FINAL CPU BENCHMARK (2 minutes)"
    log "Running final CPU benchmark (2 minutes)..."
    cores=$(nproc --all)
    sysbench cpu --cpu-max-prime=2000 --threads=$cores --time=120 --report-interval=10 run 2>&1 | tee -a "$RESULTS_FILE"
    success "Final CPU benchmark completed"
}

# Main execution function
main() {
    # Initialize results file
    init_results_file
    
    log "Starting Sysbench Comprehensive Benchmark Suite"
    log "Results will be saved to: $RESULTS_FILE"
    log "================================================"
    
    # Check prerequisites
    check_prerequisites
    
    # Setup PostgreSQL
    setup_postgresql
    
    # Run CPU benchmarks
    run_cpu_benchmarks
    
    # Clean up any existing PostgreSQL test data
    cleanup_postgresql
    
    # Prepare PostgreSQL test data
    prepare_postgresql
    
    # Run PostgreSQL benchmarks
    run_postgresql_benchmarks
    
    # Run K6 benchmarks
    run_k6_benchmarks
    
    # Final cleanup
    cleanup_postgresql
    
    # Final CPU benchmark
    run_final_cpu_benchmark
    
    # Write completion timestamp
    {
        echo ""
        echo "====================================================================="
        echo "BENCHMARK COMPLETION"
        echo "====================================================================="
        echo "End Time: $(date)"
        echo "Duration: $((SECONDS / 60)) minutes and $((SECONDS % 60)) seconds"
        echo "Results saved to: $RESULTS_FILE"
        echo "====================================================================="
    } >> "$RESULTS_FILE"
    
    log "================================================"
    success "All benchmarks completed successfully!"
    log "Detailed results saved to: $RESULTS_FILE"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -h, --help     Show this help message"
            echo "  --cpu-only     Run only CPU benchmarks"
            echo "  --db-only      Run only PostgreSQL benchmarks"
            echo "  --k6-only      Run only K6 benchmarks"
            echo "  --no-setup     Skip PostgreSQL setup"
            echo "  --no-k6        Skip K6 benchmarks"
            exit 0
            ;;
        --cpu-only)
            CPU_ONLY=true
            shift
            ;;
        --db-only)
            DB_ONLY=true
            shift
            ;;
        --k6-only)
            K6_ONLY=true
            shift
            ;;
        --no-setup)
            NO_SETUP=true
            shift
            ;;
        --no-k6)
            NO_K6=true
            shift
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute based on options
if [[ "$CPU_ONLY" == true ]]; then
    init_results_file
    log "Running CPU benchmarks only"
    log "Results will be saved to: $RESULTS_FILE"
    check_prerequisites
    run_cpu_benchmarks
    run_final_cpu_benchmark
    {
        echo ""
        echo "====================================================================="
        echo "CPU BENCHMARK COMPLETION"
        echo "====================================================================="
        echo "End Time: $(date)"
        echo "Results saved to: $RESULTS_FILE"
        echo "====================================================================="
    } >> "$RESULTS_FILE"
    success "CPU benchmarks completed! Results saved to: $RESULTS_FILE"
elif [[ "$DB_ONLY" == true ]]; then
    init_results_file
    log "Running PostgreSQL benchmarks only"
    log "Results will be saved to: $RESULTS_FILE"
    check_prerequisites
    if [[ "$NO_SETUP" != true ]]; then
        setup_postgresql
    fi
    cleanup_postgresql
    prepare_postgresql
    run_postgresql_benchmarks
    cleanup_postgresql
    {
        echo ""
        echo "====================================================================="
        echo "DATABASE BENCHMARK COMPLETION"
        echo "====================================================================="
        echo "End Time: $(date)"
        echo "Results saved to: $RESULTS_FILE"
        echo "====================================================================="
    } >> "$RESULTS_FILE"
    success "Database benchmarks completed! Results saved to: $RESULTS_FILE"
elif [[ "$K6_ONLY" == true ]]; then
    init_results_file
    log "Running K6 benchmarks only"
    log "Results will be saved to: $RESULTS_FILE"
    check_prerequisites
    run_k6_benchmarks
    {
        echo ""
        echo "====================================================================="
        echo "K6 BENCHMARK COMPLETION"
        echo "====================================================================="
        echo "End Time: $(date)"
        echo "Results saved to: $RESULTS_FILE"
        echo "====================================================================="
    } >> "$RESULTS_FILE"
    success "K6 benchmarks completed! Results saved to: $RESULTS_FILE"
else
    # Skip K6 if --no-k6 flag is used
    if [[ "$NO_K6" == true ]]; then
        K6_AVAILABLE=false
    fi
    # Run full benchmark suite
    main
fi
