Here is a comprehensive manual for the `yq` CLI tool, specifically tailored for a coding agent to understand, download, and utilize. The documentation heavily emphasizes TOML processing, which is highly relevant for manipulating files like `Cargo.toml`, `pyproject.toml`, or other modern configurations.

---

# `yq` CLI Tool Manual for Agents

## 1. Overview

[`yq` (mikefarah/yq)](https://github.com/mikefarah/yq) is a portable command-line processor for YAML, JSON, XML, CSV, and **TOML**. It uses `jq`-style syntax to traverse, filter, parse, and modify structured data.

For coding agents, `yq` is the most robust tool for **in-place updating** and **querying** of configuration files without destroying formatting, comments, or relying on fragile regex replacements.

---

## 2. Installation

`yq` is written in Go and distributed as a single, dependency-free binary. Agents can execute the following commands to install it directly into a workspace:

**Linux / CI Environments (AMD64):**

```bash
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq

```

**MacOS:**

```bash
brew install yq

```

---

## 3. Core Concepts & Flags

* **Input/Output parsing:** `yq` generally auto-detects the input format based on the file extension (e.g., `.toml`). If working with streams or standard input, you can force the parser.
* **`.` (Dot):** Represents the root node. Path navigation follows standard dot-notation (e.g., `.database.ports`).

### Important Agent Flags:

* `-i` / `--inplace`: Update the file directly instead of printing to `stdout`.
* `-o` / `--output-format`: Force the output format (`toml`, `json`, `yaml`).
* `-p` / `--input-format`: Force the input format (if file lacks a `.toml` extension).
* `-n` / `--null-input`: Do not read any input files (useful for generating files from scratch or merging).

---

## 4. Reading TOML

Given a `pyproject.toml` file:

```toml
[tool.poetry]
name = "my-project"
version = "0.1.0"
description = "Agent generated project"
authors = ["AI Agent <agent@local>"]

[tool.poetry.dependencies]
python = "^3.10"
requests = "2.31.0"

```

### Basic Extraction

Read a top-level string (outputs unquoted value):

```bash
yq '.tool.poetry.version' pyproject.toml
# Output: 0.1.0

```

Read an entire nested table section (outputs as valid TOML):

```bash
yq '.tool.poetry.dependencies' pyproject.toml
# Output:
# python = "^3.10"
# requests = "2.31.0"

```

### Array Extraction

Extract the first item from an array:

```bash
yq '.tool.poetry.authors[0]' pyproject.toml
# Output: AI Agent <agent@local>

```

---

## 5. Updating TOML (In-Place)

When an agent needs to manipulate project configurations autonomously, the `-i` flag ensures safe in-place modifications.

### Modifying a Scalar Value

```bash
yq -i '.tool.poetry.version = "1.0.0"' pyproject.toml

```

### Adding a New Key-Value Pair

If the parent table exists, simply assign the value. If it doesn't, `yq` builds the necessary nested TOML structure automatically.

```bash
yq -i '.tool.poetry.dependencies.fastapi = "^0.100.0"' pyproject.toml

```

### Updating Arrays

Append a new author to an array using the `+` operator:

```bash
yq -i '.tool.poetry.authors += ["Contributor <dev@local>"]' pyproject.toml

```

### Multiple Updates in One Pass

Pipe (`|`) expressions together to perform multiple writes in a single disk I/O operation:

```bash
yq -i '.tool.poetry.version = "1.0.1" | .tool.poetry.description = "Updated by Agent"' pyproject.toml

```

### Deleting Keys

Use the `del()` function to strip configurations:

```bash
yq -i 'del(.tool.poetry.dependencies.requests)' pyproject.toml

```

---

## 6. Advanced Operations & Filtering

### Working with Environment Variables

When an agent is handed secrets or dynamic runtime variables, using shell string interpolation (e.g., `"${VAR}"`) can break syntax due to unescaped quotes. Use `yq`'s `strenv()` to safely inject environment variables as strings:

```bash
export NEW_VERSION="2.0.0"
yq -i '.tool.poetry.version = strenv(NEW_VERSION)' pyproject.toml

```

### Filtering Array of Tables (`select`)

Given a `Cargo.toml` utilizing an array of tables:

```toml
[[bin]]
name = "server"
path = "src/server.rs"

[[bin]]
name = "client"
path = "src/client.rs"

```

Find the path of the binary named "client":

```bash
yq '.bin[] | select(.name == "client") | .path' Cargo.toml
# Output: src/client.rs

```

Update the path of a specific matching block:

```bash
yq -i '(.bin[] | select(.name == "client") | .path) = "src/bin/client/main.rs"' Cargo.toml

```

---

## 7. Formatting and File Conversions

Because `yq` translates formats into a universal intermediary tree, you can seamlessly convert TOML to JSON (for API payloads) or YAML (for CI/CD pipelines).

### TOML to JSON

Outputs a `package.json`-like structure.

```bash
yq -o json '.' pyproject.toml > pyproject.json

```

### TOML to YAML

```bash
yq -o yaml '.' pyproject.toml > config.yml
# Shorthand: yq -oy '.' pyproject.toml

```

### YAML/JSON to TOML

Conversely, if an agent generates a JSON payload and needs to write a `.toml` configuration:

```bash
yq -o toml '.' config.json > generated.toml

```

---

## 8. Merging Multiple TOML Files

Agents often need to merge base configurations with environment-specific overrides.
Given a `base.toml` and an `override.toml`:

```bash
# Deep merge two files and output as TOML
yq -n -o toml 'load("base.toml") * load("override.toml")' > merged.toml

```

*(Note: The `*` operator performs a deep merge where arrays are concatenated and matching dictionary keys are overwritten by the right-hand file).*
