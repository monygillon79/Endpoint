# UIpp-OSD-Frontend.xml

[UI++](https://uiplusplus.configmgrftw.com/) front-end configuration for an SCCM OSD task sequence: presents technicians with a guided pre-imaging wizard and writes the answers to task sequence variables.

## What it does

- Shows an authorized-use warning screen before imaging continues.
- Reads current computer name, Dell service tag, and model via WMI.
- Prompts the technician to confirm/correct the service tag, choose device location/department and OS build type, and pick software from an application tree (populates `XApplicationsA*` task sequence variables for dynamic *Install Application* steps).
- Generates the computer name and target OU placement from the answers.
- Displays a confirmation summary before handing control back to the task sequence.

## Usage

Reference this XML from the UI++ executable in a task sequence front-end step. Replace the template values first: OU paths, location/department codes, application IDs, and warning text.

## Known limitations / roadmap

- The preflight checks predate Windows 11: memory >2 GB and CPU-era flags are not sufficient. Planned modernization: UEFI, Secure Boot, TPM 2.0, RAM >= 4 GB, disk capacity, and architecture checks.
- The service-tag prompt validates length only (`.{5}`); tighten the regex if naming quality matters.
- Apps selected in the tree must have "Allow this application to be installed from the Install Application task sequence action without being deployed" enabled on every deployment type, or the dynamic install step fails with `0x80004005`.
