#!/bin/bash

# Check if the input CSV file exists
if [ ! -f "$1" ]; then
  echo "CSV file not found!"
  exit 1
fi

# Output text file
output_file="domains.txt"

# Read the CSV file, skip the header, and extract the domains
tail -n +2 "$1" | cut -d',' -f2 | tr -d '"' > "$output_file"

# Print a message to indicate the output file
echo "Domains have been extracted to '$output_file'."
