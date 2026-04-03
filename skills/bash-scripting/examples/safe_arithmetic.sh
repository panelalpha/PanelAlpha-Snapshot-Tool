#!/bin/bash
# Example: Safe Arithmetic Operations
# Demonstrates proper arithmetic with set -euo pipefail

set -euo pipefail

# WRONG - This will fail when counter is 0
# ((counter++))

# CORRECT - Safe increment
counter=0
echo "Starting counter: $counter"

counter=$((counter + 1))
echo "After increment: $counter"

# CORRECT - Safe in loops
for i in {1..5}; do
    counter=$((counter + 1))
    echo "Loop $i: counter=$counter"
done

# CORRECT - Safe with if
target=10
if [[ $counter -lt $target ]]; then
    needed=$((target - counter))
    echo "Need $needed more to reach $target"
fi

# CORRECT - Safe division (check for zero)
divisor=5
dividend=100

if [[ $divisor -ne 0 ]]; then
    result=$((dividend / divisor))
    echo "$dividend / $divisor = $result"
fi

# WRONG - Division by zero would fail
# result=$((100 / 0))

# CORRECT - With zero check
divisor=0
if [[ $divisor -ne 0 ]]; then
    result=$((dividend / divisor))
else
    result=0
    echo "Warning: Division by zero avoided"
fi

echo "Final counter: $counter"
echo "Script completed successfully!"
