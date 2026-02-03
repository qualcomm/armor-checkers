
# armor-checkers
This repository provides reusable GitHub Actions and supporting shell scripts to validate **backward compatibility** of APIs. It supports both **source level (API)** and **binary level (ABI)** checks to ensure safe, stable, and compatible changes across releases.

### Overview
The repository offers modular resuable github actions—each focused on a specific compatibility task:
*   **API Compatibility Checks:** Detect source‑level breaking changes such as removed/modified functions, structs, or enums using armor tool https://github.com/qualcomm/armor.
*   **ABI Compatibility Checks:** Validate binary‑level stability using tools like *libabigail*, identifying layout changes, symbol removals, or interface mismatches.

These actions can be integrated into any CI workflow to automatically enforce API/ABI backward compatibility across branches and releases.

## License

armor-checkers is licensed under the [BSD-3-Clause-Clear License](https://spdx.org/licenses/BSD-3-Clause-Clear.html). See [LICENSE.txt](LICENSE.txt) for the full license text.