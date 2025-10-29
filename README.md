# HTTP Protocol Detection Script

This repository contains a Bash script that detects which HTTP protocol version (HTTP/1.1, HTTP/2, or HTTP/3) websites are using.  
It was developed out of curiosity about the **current adoption and practical deployment of HTTP/3** across the web.

---

## Overview

The script takes a list of URLs, probes each one using [`curl`](https://curl.se/) (compiled with QUIC/HTTP3 support), and determines the highest HTTP version successfully negotiated.  
It sequentially attempts:
1. **HTTP/3 (QUIC)**  
2. **HTTP/2**  
3. **HTTP/1.1**

If one attempt fails, the script falls back to the next protocol.  
All results — including fallbacks, response codes, and Alt-Svc advertisements — are exported to a CSV file for later analysis.

---

## Features

- Detects the highest available HTTP version (3, 2, or 1.1) for each URL  
- Logs **fallback chains** (e.g. `h3→h2→h1.1`)  
- Detects when HTTP/3 is **advertised via Alt-Svc** but **not actually used**  
- Handles redirects and HTTPS normalization automatically  
- Outputs all results in a **CSV** file ready for data visualization or statistical analysis  

---

## Example Usage

### Input file (`urls.txt`)
```
example.com
https://www.cloudflare.com
quic.nginx.org
```

### Run the Script
```
chmod +x detect_http_protocols.sh
./detect_http_protocols.sh urls.txt results.csv
```

## Requiremends
1. Linux or macOS (Unix line endings required)
2. curl with HTTP/3 (QUIC) support. Check with:
```
curl --version
```

### List of Domains

For testing, a domain list is required.  
As an example, this project uses the [**DomCop Top 1 Million Domains**](https://www.domcop.com/top-10-million-websites) dataset.

Please note that this dataset might not always be up to date, as it changes frequently over time.  
It is therefore recommended to **generate your own list** using the provided scripts instead of relying on the pre-downloaded one.

You can use the [`extract_domains.sh`](extract_domains.sh) script to clean and format the dataset by removing unnecessary fields, keeping only valid domain names in a simple list.
