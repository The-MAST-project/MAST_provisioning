# MAST Unit Configuration Open Questions

## Status

MAST_unit service on `mast01` fails to start because `Config().get_unit()` raises a
Pydantic `ValidationError`: the MongoDB `units.common` document is missing required
fields that `UnitConfig` demands. Until these are populated, MAST_unit cannot bind
to port 8000 and the health check (`/mast/api/v1/unit/status`) will remain unreachable.

## Background

`Config` loads the unit config by:
1. Reading `C:/MAST/mast-config-db.json` on the unit (file currently absent on mast01).
2. Falling back to MongoDB at `mongodb://mast-wis-control:27017`, database `mast`,
   collection `units`.
3. Finding the `common` document and deep-merging any unit-specific document over it.
4. Constructing `UnitConfig(**merged_dict)` -- all fields are required with no defaults.

The `mast01` document was inserted (`{"name": "mast01"}`) so the unit-name lookup now
passes. However the `common` document is missing the fields listed below.

## Required fields missing from MongoDB `units.common`

### `imager` (replaces the existing `camera` key)

The existing `camera` key must be renamed to `imager` and extended:

| Field | Type | Description |
|---|---|---|
| `imager_type` | `str` | e.g. `"zwo"` or `"ascom:ASCOM.ASICamera2.Camera"` |
| `valid_imager_types` | `list[str]` | All accepted type strings |
| `pixel_scale_at_bin1` | `float` | Arcsec per pixel at binning 1 |
| `format` | `str` | Output format, e.g. `"fits"` |
| `gain` | `int` | Default camera gain |

### `mount`

The existing `mount: {}` must be populated:

| Field | Type | Description |
|---|---|---|
| `ascom_driver` | `str` | e.g. `"ASCOM.PWI4.Mount"` |

### `stage`

The existing `stage` document must be extended:

| Field | Type | Description |
|---|---|---|
| `presets.sky` | `int` | Stage position for sky (imaging) mode |
| `presets.spec` | `int` | Stage position for spectrograph mode |
| `close_enough` | `int` | Position tolerance in steps |
| `model` | `str` | Stage model identifier string |

### `phd2`

New top-level key required:

| Field | Type | Description |
|---|---|---|
| `profile` | `str` | PHD2 equipment profile name |
| `settle.pixels` | `int` | Settle threshold in pixels |
| `settle.time` | `int` | Settle time in seconds |
| `settle.timeout` | `int` | Settle timeout in seconds |
| `validation_interval` | `float` | Guiding validation interval in seconds |

### `acquisition`

New top-level key required:

| Field | Type | Description |
|---|---|---|
| `exposure` | `float` | Acquisition exposure time in seconds |
| `binning` | `int` | Camera binning for acquisition |
| `gain` | `int` | Camera gain for acquisition |
| `tries` | `int` | Maximum acquisition attempts |
| `tolerance.ra_arcsec` | `float` | RA tolerance in arcsec |
| `tolerance.dec_arcsec` | `float` | Dec tolerance in arcsec |
| `rois` | `dict` | ROI configs keyed by FcuVersion (`fcu_v1`, `fcu_v2`) |

### `guiding`

New top-level key required:

| Field | Type | Description |
|---|---|---|
| `exposure` | `float` | Guiding exposure time in seconds |
| `binning` | `int` | Camera binning for guiding |
| `gain` | `int` | Camera gain for guiding |
| `tolerance.ra_arcsec` | `float` | RA correction tolerance |
| `tolerance.dec_arcsec` | `float` | Dec correction tolerance |
| `min_ra_correction_arcsec` | `float` | Minimum RA correction to apply |
| `min_dec_correction_arcsec` | `float` | Minimum Dec correction to apply |
| `cadence_seconds` | `int` | Guiding cadence in seconds |
| `rois` | `dict` | ROI configs keyed by FcuVersion |

### `autofocus`

New top-level key required:

| Field | Type | Description |
|---|---|---|
| `exposure` | `float` | Autofocus exposure time in seconds |
| `binning` | `int` | Camera binning for autofocus |
| `images` | `int` | Number of images per focus position |
| `spacing` | `int` | Focus step spacing |
| `max_tolerance` | `int` | Max acceptable focus tolerance |
| `max_tries` | `int` | Maximum autofocus attempts |

### `solving`

New top-level key required:

| Field | Type | Description |
|---|---|---|
| `method` | `str` | Solver to use, e.g. `"planewave_cli"` |
| `valid_methods` | `list[str]` | All accepted solver method strings |

### `guider`

New top-level key required:

| Field | Type | Description |
|---|---|---|
| `method` | `str` | Guider to use, e.g. `"phd2"` |
| `valid_methods` | `list[str]` | All accepted guider method strings |

## How to fix

Option A -- populate via `mast-config-db.json` on the unit:
Write a complete config to `C:\MAST\mast-config-db.json` on mast01. This file takes
priority over MongoDB and avoids touching shared state. Use `mast77` or `mastw` as a
reference for working values.

Option B -- fill in MongoDB `units.common`:
Update the `common` document in MongoDB with the missing fields. This fixes all units
that fall back to the common base. Rename `camera` to `imager` at the same time.

## Changes already applied (not blocking)

- TCP 8000 inbound firewall rule added to `provide-mast.ps1` (for future provisions)
  and manually applied to current mast01 VM via WinRM.
- `mast01` document inserted into MongoDB `units` collection.
- NSSM log cleanup (stop service, delete stdout/stderr logs) wired into
  `--pull-repos` and `--rebuild-repos` in `run-prov-test.py`.
- MAST_unit health check (`phase_wait_for_unit_health`) added to `run-prov-test.py`
  -- polls `http://<unit>:8000/mast/api/v1/unit/status` post-start.

## Temp debug scripts to clean up

The following files were created during diagnosis and should be deleted:

- `C:\Users\labcomp2\Desktop\MAST\_open_fw.py`
- `C:\Users\labcomp2\Desktop\MAST\_check_svc.py`
- `C:\Users\labcomp2\Desktop\MAST\_get_logs.py`
- `C:\Users\labcomp2\Desktop\MAST\_check_config.py`
- `C:\Users\labcomp2\Desktop\MAST\_check_config2.py`
- `C:\Users\labcomp2\Desktop\MAST\_check_config3.py`
- `C:\Users\labcomp2\Desktop\MAST\_mongo_check.py`
- `C:\Users\labcomp2\Desktop\MAST\_mongo_seed_mast01.py`
- `C:\Users\labcomp2\Desktop\MAST\_mongo_inspect.py`
- `C:\Users\labcomp2\Desktop\MAST\_mongo_common.py`
- `C:\Users\labcomp2\Desktop\MAST\_restart_unit.py`
- `C:\Users\labcomp2\Desktop\MAST\_check_json_config.py`
