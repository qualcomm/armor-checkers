
# armor-checkers
Reusable GitHub Actions and workflows for validating backward compatibility in Qualcomm C/C++ projects.
The repository provides modular API (source‑level) and ABI (binary‑level) compatibility checks to help detect api breaking changes early in CI and ensure stable releases.

### Overview
*   **API Compatibility Check:** Detects source‑level breaking changes (e.g., modified/removed functions, structs, enums) using the ARMOR tool https://github.com/qualcomm/armor.
*   **ABI Compatibility Check:** Validates binary‑level stability using libabigail (abidiff), detecting issues such as:

    * Layout or padding changes
    * Symbol additions/removals
    * Incompatible binary interface changes

### Features
* Reusable GitHub Actions and workflows
* Automatic API/ABI comparison between base and head commits
* Works with any C/C++ project exposing public headers and build scripts
* Extensible design for future compatibility‑related checks

### Usage
Create a workflow (e.g., .github/workflows/compatibility-check.yml):

    name: Compatibility Checks

    on:
      pull_request:
        types: [opened, synchronize, reopened]


    jobs:
      armor-checkers:
        uses: qualcomm/armor-checkers/.github/workflows/armor-checker.yml@v2
        with:
          armor-checker-options: >-
            {
            "build-script": "ci/build.sh",

            // Optional: Use runner groups / self‑hosted runner labels
            "runs-on": {
                "group": "",
                "labels": ["", ""]
            }

            // Or use a simple GitHub-hosted runner (default)
            // "runs-on": "ubuntu-latest"
            }

This integrates automatic API/ABI backward‑compatibility validation into your CI pipeline.

### Configuration options
 `armor-checker-options` is a JSON parameter passed to the reusable workflow. It controls how API/ABI checks run.
 * **Supported fields:**
* `build-script` **(required for ABI checks)**
   * Specifies the script path that builds the project and generates binaries for ABI comparison.
   * Default: ci/build.sh
   * Update if the build script path changes

* `runs-on` **(required for API & ABI)**
   * Defines which runner to execute the checks on.
   * If your project already uses AWS self‑hosted runners,it is **recommended** to use them for armor-checkers, because they provide the necessary access for ARMOR Checkers workflow to upload API/ABI metrics to the S3 bucket.
   * If omitted, GitHub‑hosted runners are used by default; however, in this case ARMOR Checkers cannot upload API/ABI metrics to the S3 bucket.
```
      "runs-on": {
        "group": "aws-runner-group",
        "labels": ["label1", "label2"]
      }
```
## License

armor-checkers is licensed under the [BSD-3-Clause-Clear License](https://spdx.org/licenses/BSD-3-Clause-Clear.html). See [LICENSE.txt](LICENSE.txt) for the full license text.
