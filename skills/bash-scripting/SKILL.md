# Bash Scripting Skill

Bash scripting patterns and best practices for the PanelAlpha Snapshot Tool.

## Overview

This skill covers the specific bash patterns used throughout `pasnap.sh`. The script uses `set -euo pipefail` for strict error handling, which requires careful coding practices.

## Critical Patterns

### 1. Arithmetic Operations

**NEVER use `((var++))`** - it returns exit code 1 when var is 0, causing the script to abort with `set -e`.

```bash
# WRONG - will cause script to exit when retry_count is 0
((retry_count++))

# CORRECT - safe increment
retry_count=$((retry_count + 1))

# CORRECT - safe decrement
retry_count=$((retry_count - 1))

# CORRECT - safe addition
total=$((value1 + value2))
```

### 2. Variable Declaration

Always declare variables properly, especially with command substitution:

```bash
# WRONG - local exits with failure if command fails
local result=$(some_command)

# CORRECT - separate declaration and assignment
local result
result=$(some_command)

# CORRECT - with default value
local result
result=$(some_command 2>/dev/null || echo "default")
```

### 3. Error Handling with `set -euo pipefail`

The script uses strict mode. Handle potential failures:

```bash
# Check if command succeeds before using output
if ! container=$(docker compose ps -q service 2>/dev/null); then
    log ERROR "Failed to get container"
    return 1
fi

# Use || true for optional operations
optional_operation || true

# Check file existence before operations
if [[ -f "$file" ]]; then
    process_file "$file"
fi
```

### 4. Logging

Always use the `log()` function for output:

```bash
log INFO "Starting operation"
log WARN "Something unexpected happened"
log ERROR "Operation failed"
log DEBUG "Detailed info: $variable"
```

### 5. Function Structure

```bash
my_function() {
    local param1="$1"
    local param2="$2"
    local local_var
    
    # Validate inputs
    if [[ -z "$param1" ]]; then
        log ERROR "param1 is required"
        return 1
    fi
    
    # Main logic
    if some_operation; then
        log INFO "Success"
    else
        log ERROR "Failed"
        return 1
    fi
}
```

### 6. Arrays

```bash
# Declare arrays
declare -a my_array=("item1" "item2" "item3")
local -a local_array=("a" "b" "c")

# Iterate
for item in "${my_array[@]}"; do
    process "$item"
done

# Get length
local count=${#my_array[@]}

# Safe access with default
local first_item="${my_array[0]:-default}"
```

### 7. String Operations

```bash
# Extract from variable
local filename="${full_path##*/}"      # basename
local dirname="${full_path%/*}"        # dirname
local extension="${filename##*.}"      # extension
local name="${filename%.*}"            # name without extension

# Substitution
local cleaned="${variable// /_}"       # replace spaces with underscores
local lower="${variable,,}"            # lowercase
local upper="${variable^^}"            # uppercase

# Default values
local value="${variable:-default}"
local value="${variable:=default}"     # set if unset
```

### 8. Input Validation

```bash
validate_input() {
    local input="$1"
    local type="$2"
    
    case "$type" in
        "snapshot_id")
            if [[ ! "$input" =~ ^[a-zA-Z0-9]{8}$|^latest$ ]]; then
                log ERROR "Invalid snapshot ID format: $input"
                return 1
            fi
            ;;
        "path")
            if [[ "$input" =~ \.\.|^/dev/|^/sys/|^/proc/ ]]; then
                log ERROR "Invalid path: $input"
                return 1
            fi
            ;;
        "number")
            if ! [[ "$input" =~ ^[0-9]+$ ]]; then
                log ERROR "Not a number: $input"
                return 1
            fi
            ;;
    esac
    return 0
}
```

## Code Style

### Indentation
- Use 4 spaces (not tabs)
- Align related items

```bash
if [[ "$condition" == true ]]; then
    do_something
    do_something_else
fi
```

### Quoting
- Always quote variables: `"$variable"`
- Quote arrays: `"${array[@]}"`
- Don't quote numbers or patterns

```bash
cp "$source" "$destination"
for item in "${array[@]}"; do
    echo "$item"
done
```

### Function Naming
- Use lowercase with underscores
- Be descriptive
- Use verbs for actions

```bash
create_snapshot()
validate_repository_config()
restore_databases()
show_progress()
```

### Variable Naming
- Local variables: lowercase with underscores
- Constants: UPPERCASE with underscores
- Environment: UPPERCASE

```bash
local temp_dir
local retry_count
readonly MAX_RETRIES=3
readonly SCRIPT_VERSION="1.2.1"
```

## Common Pitfalls

### 1. Unset Variables
With `set -u`, unset variables cause errors:

```bash
# WRONG
value=$UNSET_VARIABLE

# CORRECT - with default
value="${UNSET_VARIABLE:-default}"

# CORRECT - check first
if [[ -n "${UNSET_VARIABLE:-}" ]]; then
    value="$UNSET_VARIABLE"
fi
```

### 2. Pipe Failures
With `set -o pipefail`, any command in a pipe can fail:

```bash
# WRONG - grep failure causes exit
cat file | grep pattern | wc -l

# CORRECT - handle potential failures
cat file 2>/dev/null | grep pattern 2>/dev/null | wc -l || echo 0

# CORRECT - avoid pipe if possible
grep -c pattern file 2>/dev/null || echo 0
```

### 3. Division by Zero
Always check before division:

```bash
# WRONG
total=$((sum / count))

# CORRECT
if [[ $count -gt 0 ]]; then
    total=$((sum / count))
else
    total=0
fi
```

## Testing Functions

```bash
# Test with bash -n for syntax
test_syntax() {
    bash -n pasnap.sh
}

# Test specific function
test_function() {
    source pasnap.sh
    my_function "test_arg"
}
```

## Resources

- [Bash Manual](https://www.gnu.org/software/bash/manual/)
- [ShellCheck](https://www.shellcheck.net/) - Use for static analysis
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
