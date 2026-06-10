# YottaDB MUMPS HIE Platform — Technical Documentation

**Project:** Clinical AI Infrastructure for Liver Transplant Candidate Identification  
**Author:** Harkirat Dhillon, Senior PM & Lead Clinical Informaticist, Northwell Health  
**Version:** 1.0  
**Date:** June 2026  

---

## 1. Platform Overview

This document describes the YottaDB MUMPS global structure used as the canonical
Health Information Exchange (HIE) store for the MIMIC-III and MIMIC-IV clinical
research datasets. The platform implements a dual-architecture design:

```
Layer 1:  YottaDB ^PHD globals       — hierarchical B-tree, co-located patient data
Layer 2:  PostgreSQL hie.* schema    — OMOP-aligned analytics layer
Layer 3:  Consumers                  — ML models, LLM pipelines, RAG inference

Data flow: PostgreSQL (source) → ETL → YottaDB ^PHD (canonical HIE store)
           YottaDB ^PHD → Feature extraction → ML models
```

---

## 2. YottaDB Version and Environment

### Software Version

```
Database engine:  YottaDB r2.06 (x86_64)
Distribution:     hie-mumps Docker image
Language:         MUMPS (M language), ISO/IEC 11756:1999
Python binding:   yottadb Python package (pip3)
```

### Runtime Environment

```
Container:        Docker (mumps-bench)
Container ID:     b4098bed0d16
Base OS:          Ubuntu 24.04 (linux/amd64)

Environment variables:
  ydb_gbldir  = /data/r2.06_x86_64/g/yottadb.gld
  gtmdir      = /data
  ydb_dist    = /opt/yottadb/current

File locations:
  Database file:    /data/r2.06_x86_64/g/yottadb.dat
  Global directory: /data/r2.06_x86_64/g/yottadb.gld
  Journal file:     /data/r2.06_x86_64/g/yottadb.mjl
  ETL scripts:      /project/load/
  ML scripts:       /project/liver/
```

### Windows Mount Configuration

```
Windows path                              Container path
─────────────────────────────────────────────────────────
C:\Users\User\Phd mumps\data\ydb\     →  /data
C:\Users\User\Phd mumps\              →  /project
```

### Docker Run Command

```powershell
docker run -d --name mumps-bench `
  --entrypoint "/bin/bash" `
  -v "C:\Users\User\Phd mumps\data\ydb:/data" `
  -v "C:\Users\User\Phd mumps:/project" `
  -p 9080-9081:9080-9081 `
  harkiratdhillon/hie-clinical-ai:v1.0 `
  -c "while true; do sleep 30; done"
```

---

## 3. Data Sources Loaded

### MIMIC-III (Beth Israel Deaconess, 2001-2012)

```
Source:       PhysioNet MIMIC-III Clinical Database v1.4
PostgreSQL:   MIMICold database (host.docker.internal:5432)
Schema:       public.*
ICD version:  ICD-9 only
Setting:      ICU only (Beth Israel Deaconess Medical Center)
```

| Table | Rows | Loaded to ^PHD |
|-------|------|----------------|
| patients | 46,520 | ✓ |
| admissions | 58,976 | ✓ |
| diagnoses_icd | 651,047 | ✓ |
| labevents | 27,854,055 | ✓ (9,220,052 scored) |
| prescriptions | 4,156,450 | ✓ |
| noteevents | 2,083,180 | ✓ (800,472 clinical notes) |
| icustays | 61,532 | ✓ |

### MIMIC-IV (Beth Israel Deaconess, 2008-2019)

```
Source:       PhysioNet MIMIC-IV Clinical Database v2.0+
PostgreSQL:   MIMICIV database (host.docker.internal:5432)
Schemas:      hosp.*, icu.*
ICD version:  ICD-9 (pre-2016) + ICD-10 (post-2015)
Setting:      Hospital-wide (ICU + general ward)
COVID era:    2020-2022 excluded from ML validation (8.2% mortality outlier)
```

| Table | Postgres Rows | Loaded to ^PHD | Status |
|-------|--------------|----------------|--------|
| hosp.patients | 364,627 | 364,628 | ✓ Complete |
| hosp.admissions | 546,028 | 546,028 | ✓ Complete |
| hosp.diagnoses_icd | 1,048,552 | 1,048,552 | ✓ Complete |
| hosp.prescriptions | 20,292,611 | 20,292,610 | ✓ Complete |
| icu.icustays | 94,458 | 94,458 | ✓ Complete |
| icu.outputevents | 5,359,395 | 5,195,281 | ✓ Complete |
| hosp.labevents | 158,374,764 | loading... | ⏳ In progress |

---

## 4. The ^PHD Global — Design Principles

### Why a Single Global?

MUMPS B-tree globals store data hierarchically. By placing all clinical data
for a patient under a single root key, we achieve:

```
Co-location:    All data for one patient stored adjacently on disk
Single descent: One B-tree traversal retrieves entire patient history
No joins:       Demographics + labs + meds + diagnoses in one operation
Cache locality: Sequential reads — CPU cache exploited efficiently
```

### Performance vs PostgreSQL

```
Operation                  PostgreSQL    YottaDB    Speedup
───────────────────────────────────────────────────────────
Point lookup (1 patient)   ~40ms         ~2ms       20x
Feature extraction (3,382) 79s           23.5s      3.4x
Context assembly (1,000)   ~90s (est)    ~5s (est)  ~18x
```

---

## 5. ^PHD Global Structure — Complete Specification

### 5.1 Top-Level Key Design

```
^PHD(pid, ...)          Patient data node
^PHD("BSRC", ...)       Backward source index (reverse lookup)
^PHD("BENC", ...)       Backward encounter index
```

### 5.2 Patient ID (PID) Format

```
MIMIC-III:  "HIE-MIII-XXXXXX"   (6-digit zero-padded subject_id)
            Example: "HIE-MIII-000124"  ← subject_id = 124

MIMIC-IV:   "HIE-MIV-XXXXXXXX"  (8-digit subject_id, no padding needed)
            Example: "HIE-MIV-10000032" ← subject_id = 10000032

Prefix purpose:
  HIE   = Health Information Exchange (project namespace)
  MIII  = Source: MIMIC-III
  MIV   = Source: MIMIC-IV
```

### 5.3 Encounter ID (EID) Format

```
MIMIC-III:  "ENC-MIII-XXXXXXXX"  (8-digit zero-padded hadm_id)
            Example: "ENC-MIII-026820668" ← hadm_id = 26820668

MIMIC-IV:   "ENC-MIV-XXXXXXXX"   (8-digit hadm_id)
            Example: "ENC-MIV-22841357"  ← hadm_id = 22841357
```

---

## 6. ^PHD Node Definitions — Field by Field

### 6.1 Patient Demographics Node

```
^PHD(pid, "SRC")
  Value:  source tag ("MIII" or "MIV")
  Example: ^PHD("HIE-MIV-10000032","SRC") = "MIV"

^PHD(pid, "PID")
  Value:  subject_id ^ gender ^ anchor_age ^ anchor_year ^
          anchor_year_group ^ dod
  Fields:
    [1] subject_id        INTEGER   Original MIMIC subject ID
    [2] gender            TEXT      "M" or "F"
    [3] anchor_age        INTEGER   Age at anchor year
    [4] anchor_year       INTEGER   Reference year (shifted for privacy)
    [5] anchor_year_group TEXT      Real calendar era e.g. "2014 - 2016"
    [6] dod               DATE      Date of death (blank if alive)

  Example:
    ^PHD("HIE-MIV-10000032","PID") =
      "10000032^F^52^2180^2014 - 2016^"

  Postgres source: hosp.patients
    SELECT subject_id, gender, anchor_age,
           anchor_year, anchor_year_group, dod
    FROM hosp.patients
```

### 6.2 Admission (Visit) Node

```
^PHD(pid, "VISIT", eid, "0")
  Value:  admittime ^ dischtime ^ admission_type ^ location ^
          insurance ^ hospital_expire_flag ^ status ^ los_hours ^
          had_icu
  Fields:
    [1] admittime            DATETIME  "YYYY-MM-DD HH:MM:SS"
    [2] dischtime            DATETIME  "YYYY-MM-DD HH:MM:SS"
    [3] admission_type       TEXT      "URGENT", "ELECTIVE", "EMERGENCY"
    [4] location             TEXT      (blank in MIV)
    [5] insurance            TEXT      "Medicare", "Medicaid", "Private"
    [6] hospital_expire_flag INTEGER   1=died, 0=survived
    [7] status               TEXT      (blank)
    [8] los_hours            FLOAT     Length of stay in hours
    [9] had_icu              INTEGER   1=had ICU stay, 0=ward only

  Example:
    ^PHD("HIE-MIV-10000032","VISIT","ENC-MIV-22841357","0") =
      "2180-05-06 22:23:00^2180-05-07 18:15:00^URGENT^^Medicare^0^^20.1^1"

  Postgres source (MIMIC-IV):
    SELECT a.admittime, a.dischtime, a.admission_type,
           a.insurance, a.hospital_expire_flag,
           EXTRACT(EPOCH FROM (a.dischtime-a.admittime))/3600,
           CASE WHEN i.hadm_id IS NOT NULL THEN 1 ELSE 0 END
    FROM hosp.admissions a
    LEFT JOIN (SELECT DISTINCT hadm_id FROM icu.icustays) i
        ON a.hadm_id=i.hadm_id
```

### 6.3 Diagnosis Nodes

```
^PHD(pid, "VISIT", eid, "DX", seq_num)
  Value:  icd_code ^ icd_version ^ long_title ^ seq_num
  Fields:
    [1] icd_code      TEXT     ICD-9 or ICD-10 code
    [2] icd_version   INTEGER  9 or 10
    [3] long_title    TEXT     Full diagnosis description
    [4] seq_num       INTEGER  Sequence (1=primary, 2+=secondary)

  Example (MIMIC-IV ICD-10):
    ^PHD("HIE-MIV-10000032","VISIT","ENC-MIV-22841357","DX","1") =
      "K7200^10^Hepatic failure unspecified without coma^1"

  Example (MIMIC-III ICD-9):
    ^PHD("HIE-MIII-000124","VISIT","ENC-MIII-026820668","DX","1") =
      "5715^9^Cirrhosis of liver without mention of alcohol^1"

  Postgres source (MIMIC-IV):
    SELECT d.seq_num, d.icd_code, d.icd_version,
           COALESCE(di.long_title,'')
    FROM hosp.diagnoses_icd d
    LEFT JOIN hosp.d_icd_diagnoses di
        ON d.icd_code=di.icd_code AND d.icd_version=di.icd_version

  Note: MIMIC-IV contains BOTH ICD-9 (pre-2016) and ICD-10 (post-2015)
        icd_version field distinguishes them
        MIMIC-III contains ICD-9 only (icd_version always 9)
```

### 6.4 Lab Result Nodes

```
^PHD(pid, "VISIT", eid, "LAB", n)
  Value:  itemid ^ valuenum ^ valueuom ^ flag ^ charttime ^
          label ^ fluid ^ category ^ ref_range_lower ^ ref_range_upper
  Fields:
    [1] itemid          INTEGER  Lab item ID (d_labitems.itemid)
    [2] valuenum        FLOAT    Numeric result value
    [3] valueuom        TEXT     Unit of measure (e.g. "mg/dL", "mEq/L")
    [4] flag            TEXT     "abnormal" or blank
    [5] charttime       DATETIME When lab was drawn
    [6] label           TEXT     Lab name (e.g. "Bilirubin, Total")
    [7] fluid           TEXT     Specimen type (e.g. "Blood", "Urine")
    [8] category        TEXT     Lab category (e.g. "Chemistry")
    [9] ref_range_lower FLOAT    Normal range lower bound
   [10] ref_range_upper FLOAT    Normal range upper bound

  Example:
    ^PHD("HIE-MIV-10000032","VISIT","ENC-MIV-22841357","LAB","1") =
      "50885^3.2^mg/dL^abnormal^2180-05-06 14:22:00^
       Bilirubin, Total^Blood^Chemistry^^"

  Key Lab Item IDs (same across MIMIC-III and MIMIC-IV):
    50885  Bilirubin Total      mg/dL    MELD component
    50912  Creatinine           mg/dL    MELD component
    51237  INR (PT)             ratio    MELD component
    50983  Sodium               mEq/L    MELD-Na component
    50824  Sodium (serum)       mEq/L    MELD-Na alternate
    50878  AST                  IU/L     Liver inflammation
    50861  ALT (SGPT)           IU/L     Liver inflammation
    50862  Albumin              g/dL     Synthetic function
    51265  Platelet Count       K/uL     Hypersplenism
    50924  Ferritin             ng/mL    Iron overload
    50927  GGT                  IU/L     Biliary disease
    50863  Alkaline Phosphatase IU/L     Biliary/bone
    51301  White Blood Cells    K/uL     Infection
    51222  Hemoglobin           g/dL     Anemia

  Postgres source (MIMIC-IV):
    SELECT l.itemid, l.valuenum, l.valueuom,
           l.flag, l.charttime
    FROM hosp.labevents l
    WHERE l.valuenum IS NOT NULL AND l.hadm_id IS NOT NULL
```

### 6.5 Medication Nodes

```
^PHD(pid, "VISIT", eid, "MED", n)
  Value:  drug ^ gsn ^ drug_type ^ dose_val ^ dose_unit ^
          route ^ starttime ^ stoptime
  Fields:
    [1] drug        TEXT     Drug name (e.g. "Lactulose")
    [2] gsn         TEXT     Generic Sequence Number
    [3] drug_type   TEXT     "BASE", "ADDITIVE", "MAIN"
    [4] dose_val    TEXT     Dose value (e.g. "30")
    [5] dose_unit   TEXT     Dose unit (e.g. "mL", "mg")
    [6] route       TEXT     Administration route
    [7] starttime   DATETIME When medication started
    [8] stoptime    DATETIME When medication stopped

  Route classification for clinical features:
    CHRONIC (oral):  PO, PO/NG, ORAL, NG, G TUBE, J TUBE
    ACUTE (IV):      IV, IV DRIP, IV INFUSION, IV BOLUS

  Key medications tracked:
    Lactulose      PO   Encephalopathy management
    Rifaximin      PO   Encephalopathy prophylaxis
    Spironolactone PO   Ascites management
    Furosemide     PO   Ascites/edema (chronic)
    Furosemide     IV   Ascites/edema (acute escalation)
    Albumin        IV   Spontaneous bacterial peritonitis
    Nadolol/       PO   Variceal bleeding prophylaxis
    Propranolol
    Octreotide     IV   Active variceal bleeding
    Vasopressin    IV   Refractory variceal bleeding
    Midodrine      PO   Hepatorenal syndrome

  Escalation signal:
    on_furosemide_po = 1 AND on_furosemide_iv = 1
    → Patient failing outpatient management

  Postgres source (MIMIC-IV):
    SELECT drug, gsn, drug_type, dose_val_rx,
           dose_unit_rx, route, starttime, stoptime
    FROM hosp.prescriptions
```

### 6.6 ICU Stay Nodes

```
^PHD(pid, "VISIT", eid, "ICU", stay_id, "0")
  Value:  first_careunit ^ intime ^ outtime ^ los ^ source
  Fields:
    [1] first_careunit  TEXT   ICU unit name (e.g. "Medical Intensive Care Unit")
    [2] intime          DATETIME ICU admission time
    [3] outtime         DATETIME ICU discharge time
    [4] los             FLOAT    ICU length of stay in days
    [5] source          TEXT     "MIII" or "MIV"

  Example:
    ^PHD("HIE-MIV-10000032","VISIT","ENC-MIV-28576410",
         "ICU","39553770","0") =
      "Medical Intensive Care Unit^2180-06-26 21:00:00^
       2180-06-29 15:00:00^2.75^MIV"

  Postgres source (MIMIC-IV):
    SELECT stay_id, first_careunit, last_careunit,
           intime, outtime, los
    FROM icu.icustays
```

### 6.7 Output Events Nodes (MIMIC-IV only)

```
^PHD(pid, "VISIT", eid, "OUT", n)
  Value:  itemid ^ value ^ valueuom ^ charttime
  Fields:
    [1] itemid    INTEGER  Output item ID
    [2] value     FLOAT    Output volume
    [3] valueuom  TEXT     Unit (e.g. "mL")
    [4] charttime DATETIME When recorded

  Clinical use:
    Urine output tracking — key signal for hepatorenal syndrome
    Oliguria (< 400mL/day) = hepatorenal criterion

  Postgres source (MIMIC-IV):
    SELECT o.itemid, o.value, o.valueuom, o.charttime
    FROM icu.outputevents o
    JOIN icu.icustays i ON o.stay_id=i.stay_id
```

---

## 7. Reverse Index Structure

### 7.1 BSRC — Backward Source Index

```
Purpose: Find YottaDB PID key given a source subject_id

^PHD("BSRC", source, subject_id, pid_key) = "1"

Examples:
  ^PHD("BSRC","MIII","124","HIE-MIII-000124")    = "1"
  ^PHD("BSRC","MIV","10000032","HIE-MIV-10000032") = "1"

Usage in Python:
  # Find MIMIC-IV patient with subject_id = 10000032
  pid = ydb.get("^PHD", ["BSRC","MIV","10000032"])
  # Returns: b'HIE-MIV-10000032'

Admission reverse index:
  ^PHD("BSRC", source, "ADM", hadm_id, pid_key, eid_key) = "1"

  Example:
  ^PHD("BSRC","MIV","ADM","22841357",
       "HIE-MIV-10000032","ENC-MIV-22841357") = "1"

  Usage: Find patient and encounter given a hadm_id
```

---

## 8. MELD Score Computation

The MELD-Na score is computed from ^PHD lab data using:

```
Labs required (peak within admission):
  bilirubin:  itemid 50885 (peak value)
  creatinine: itemid 50912 (peak value)
  inr:        itemid 51237 (last value)
  sodium:     itemid 50983 or 50824 (last value)

UNOS constraints applied:
  bilirubin:  max(1.0, min(82.0,  bili))
  creatinine: max(1.0, min(4.0,   creat))
  inr:        max(1.0, min(10.0,  inr))
  sodium:     max(125.0, min(137.0, sodium))

MELD formula:
  MELD = 3.78×ln(bili) + 11.2×ln(INR) + 9.57×ln(creat) + 6.43

MELD-Na formula:
  MELD-Na = MELD + 1.32×(137-Na) - 0.033×MELD×(137-Na)
  Bounded: max(6, min(40, MELD-Na))

Severity bands:
  Low       MELD  6-9   Routine monitoring
  Moderate  MELD 10-19  Enhanced follow-up
  High      MELD 20-29  Transplant evaluation
  Urgent    MELD 30+    Priority listing
```

---

## 9. Reading Data from ^PHD — Code Examples

### 9.1 Python Setup

```python
import os
os.environ['ydb_gbldir'] = '/data/r2.06_x86_64/g/yottadb.gld'
import yottadb as ydb

def ydb_get(subs):
    """Get a value from ^PHD"""
    try:
        r = ydb.get("^PHD", list(subs))
        return r.decode() if isinstance(r, bytes) else r
    except:
        return None

def ydb_set(subs, value):
    """Set a value in ^PHD"""
    ydb.set("^PHD", list(subs), str(value))

def ydb_next(subs):
    """Get next subscript — returns None at end"""
    try:
        r = ydb.subscript_next("^PHD", list(subs))
        return r.decode() if isinstance(r, bytes) else r
    except ydb.YDBNodeEnd:
        return None
    except:
        return None
```

### 9.2 Get Patient Demographics

```python
# Look up a MIMIC-IV patient
pid = "HIE-MIV-10000032"
data = ydb_get([pid, "PID"])
parts = data.split("^")
subject_id  = parts[0]   # "10000032"
gender      = parts[1]   # "F"
age         = parts[2]   # "52"
era         = parts[4]   # "2014 - 2016"
```

### 9.3 Get All Admissions for a Patient

```python
pid = "HIE-MIV-10000032"
eid = ydb_next([pid, "VISIT", ""])
while eid:
    adm_data = ydb_get([pid, "VISIT", eid, "0"])
    parts = adm_data.split("^")
    admittime = parts[0]
    dischtime = parts[1]
    expired   = parts[5]
    los_hours = parts[7]
    had_icu   = parts[8]
    print(f"  {eid}: {admittime} → {dischtime} ICU={had_icu}")
    eid = ydb_next([pid, "VISIT", eid])
```

### 9.4 Get Labs for an Admission

```python
pid = "HIE-MIV-10000032"
eid = "ENC-MIV-22841357"

n = ydb_next([pid, "VISIT", eid, "LAB", ""])
while n:
    lab = ydb_get([pid, "VISIT", eid, "LAB", n])
    parts = lab.split("^")
    itemid    = parts[0]   # "50885"
    valuenum  = parts[1]   # "3.2"
    uom       = parts[2]   # "mg/dL"
    flag      = parts[3]   # "abnormal"
    charttime = parts[4]   # "2180-05-06 14:22:00"
    label     = parts[5]   # "Bilirubin, Total"
    print(f"  {label}: {valuenum} {uom} ({flag})")
    n = ydb_next([pid, "VISIT", eid, "LAB", n])
```

### 9.5 Find Patient by Source ID

```python
# Find MIMIC-IV patient with subject_id = 10000032
pid = ydb_get(["BSRC", "MIV", "10000032"])
# Returns: "HIE-MIV-10000032"

# Find MIMIC-III patient with subject_id = 124
pid = ydb_get(["BSRC", "MIII", "124"])
# Returns: "HIE-MIII-000124"
```

### 9.6 Build Patient Narrative for LLM

```python
def build_narrative(pid):
    """Build clinical narrative text from ^PHD for LLM input"""
    demo = ydb_get([pid, "PID"]).split("^")
    gender = "Male" if demo[1]=="M" else "Female"
    age    = demo[2]
    src    = "MIMIC-III" if "MIII" in pid else "MIMIC-IV"

    narrative = f"Patient: {age}-year-old {gender} ({src})\n\n"

    eid = ydb_next([pid, "VISIT", ""])
    adm_num = 0
    while eid:
        adm_num += 1
        adm = ydb_get([pid, "VISIT", eid, "0"]).split("^")
        narrative += f"Admission {adm_num} ({adm[0][:10]}):\n"

        # Diagnoses
        dx_list = []
        n = ydb_next([pid, "VISIT", eid, "DX", ""])
        while n:
            dx = ydb_get([pid, "VISIT", eid, "DX", n]).split("^")
            dx_list.append(dx[2])
            n = ydb_next([pid, "VISIT", eid, "DX", n])
        if dx_list:
            narrative += f"  Diagnoses: {', '.join(dx_list[:3])}\n"

        # Key labs
        labs = {}
        n = ydb_next([pid, "VISIT", eid, "LAB", ""])
        while n:
            lab = ydb_get([pid, "VISIT", eid, "LAB", n]).split("^")
            itemid = int(lab[0]) if lab[0].isdigit() else 0
            if itemid in [50885,50912,51237,50983]:
                name = lab[5] if len(lab)>5 else str(itemid)
                val  = lab[1]
                uom  = lab[2]
                labs[name] = f"{val} {uom}"
            n = ydb_next([pid, "VISIT", eid, "LAB", n])
        for name, val in labs.items():
            narrative += f"  {name}: {val}\n"

        narrative += f"  LOS: {adm[7]} hours\n\n"
        eid = ydb_next([pid, "VISIT", eid])

    return narrative
```

---

## 10. ETL Scripts

### 10.1 MIMIC-III ETL

```
Script:   /project/load/load_mimic3.py  (original)
          /project/load/etl_mumps.py    (enhanced version)
Runtime:  ~2 hours for full dataset
Records:  46,520 patients, 9.2M labs, 4.1M meds
```

### 10.2 MIMIC-IV ETL

```
Script:   /project/load/etl_mimiciv.py
Runtime:  ~1.5 hours total (medications + labs + output)
Records:  364,627 patients, 158M labs, 20M meds

Load order (important — admissions must precede labs):
  Step 1: patients      (364,627 rows,  ~0.1 min,  97,771/s)
  Step 2: admissions    (546,028 rows,  ~0.5 min,  16,817/s)
  Step 3: diagnoses   (1,048,552 rows,  ~0.2 min, 106,955/s)
  Step 4: icu            (94,458 rows,  ~0.2 min,   6,763/s)
  Step 5: medications (20,292,611 rows, ~6.1 min,  55,867/s)
  Step 6: output       (5,359,395 rows, ~1.6 min,  57,290/s)
  Step 7: labs       (158,374,764 rows, ~42 min,   62,373/s)

Resume capability:
  Labs step saves offset to /tmp/lab_etl_offset.txt
  If interrupted: re-run --steps labs to resume automatically

Memory note:
  Uses server-side PostgreSQL cursor (itersize=10,000)
  Memory usage: ~90MB (not 7GB like naive fetchall)
```

### 10.3 Run Commands

```bash
# Full load (all steps)
python3 /project/load/etl_mimiciv.py --steps all

# Specific steps only
python3 /project/load/etl_mimiciv.py --steps patients admissions diagnoses

# Labs only (resumable)
python3 /project/load/etl_mimiciv.py --steps labs

# Background overnight load
nohup python3 /project/load/etl_mimiciv.py --steps labs \
    > /tmp/etl_labs.log 2>&1 &

# Monitor progress
tail -f /tmp/etl_labs.log
```

---

## 11. Database Maintenance

### 11.1 Journal Recovery (after crash)

```bash
# Run after Docker crash or unclean shutdown
/opt/yottadb/current/mupip journal \
    -recover -backward \
    /data/r2.06_x86_64/g/yottadb.mjl

# Verify recovery succeeded
echo "Exit: $?"  # Should be 0
```

### 11.2 Database Rundown (clean shutdown)

```bash
/opt/yottadb/current/mupip rundown -region DEFAULT
```

### 11.3 Check Database Size

```bash
du -sh /data/r2.06_x86_64/g/
ls -lh /data/r2.06_x86_64/g/yottadb.dat
```

---

## 12. Backup and Recovery

### Current Backup Location: D:\backup\

```
D:\backup\ydb\              MUMPS ^PHD globals (Windows copy)
D:\backup\postgres\
  MIMICIV.dump              MIMIC-IV PostgreSQL (5.6 GB compressed)
  MIMICold.dump             MIMIC-III PostgreSQL (3.0 GB compressed)
D:\backup\docker\
  hie-clinical-ai-v1.0.tar  Docker image (1.5 GB)
D:\backup\project\          All scripts and code
```

### Restore on New Machine

```powershell
# 1. Install Docker Desktop
# 2. Load image
docker load -i D:\backup\docker\hie-clinical-ai-v1.0.tar

# 3. Restore YDB data
xcopy D:\backup\ydb\ "C:\Users\User\Phd mumps\data\ydb\" /E /I /H /Y

# 4. Start container
docker run -d --name mumps-bench `
  --entrypoint "/bin/bash" `
  -v "C:\Users\User\Phd mumps\data\ydb:/data" `
  -v "C:\Users\User\Phd mumps:/project" `
  -p 9080-9081:9080-9081 `
  harkiratdhillon/hie-clinical-ai:v1.0 `
  -c "while true; do sleep 30; done"
```

---

## 13. PostgreSQL to ^PHD Mapping Summary

| PostgreSQL Table | ^PHD Node | Key Format |
|-----------------|-----------|------------|
| hosp.patients | ^PHD(pid,"PID") | subject_id^gender^age^year^era^dod |
| hosp.admissions | ^PHD(pid,"VISIT",eid,"0") | admit^disch^type^^ins^expire^^los^icu |
| hosp.diagnoses_icd | ^PHD(pid,"VISIT",eid,"DX",seq) | code^version^title^seq |
| hosp.labevents | ^PHD(pid,"VISIT",eid,"LAB",n) | itemid^val^uom^flag^time^label^fluid^cat |
| hosp.prescriptions | ^PHD(pid,"VISIT",eid,"MED",n) | drug^gsn^type^dose^unit^route^start^stop |
| icu.icustays | ^PHD(pid,"VISIT",eid,"ICU",stay_id,"0") | unit^in^out^los^src |
| icu.outputevents | ^PHD(pid,"VISIT",eid,"OUT",n) | itemid^val^uom^time |
| — | ^PHD("BSRC",src,sid,pid) | Reverse patient lookup |
| — | ^PHD("BSRC",src,"ADM",hid,pid,eid) | Reverse admission lookup |

---

*Document maintained by Harkirat Dhillon*  
*Last updated: June 2026*  
*Repository: https://github.com/harkiratdhillon42482/Liver-deterioration*
