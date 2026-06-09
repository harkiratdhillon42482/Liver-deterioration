# Liver Transplant Candidate Identification — Temporal Validation Study

> ⚠️ **RESEARCH ONLY — NOT FOR CLINICAL USE**
> This project was developed for research and educational purposes under
> PhysioNet MIMIC-III and MIMIC-IV Data Use Agreements.
> Model outputs must NOT be used for clinical decision-making,
> patient care, diagnosis, or treatment decisions.

## Live Pages

| Page | Description |
|------|-------------|
| [Results Dashboard](https://harkiratdhillon42482.github.io/Liver-deterioration/) | Full results, charts, patient cases, methodology |
| [Full Paper](https://harkiratdhillon42482.github.io/Liver-deterioration/paper.html) | Abstract, methods, results, discussion, references |

---

## What This Project Does

A machine learning model trained on MIMIC-III ICU liver patients (2001-2012)
is applied to MIMIC-IV hospital patients (2008-2019) to predict which patients
will significantly deteriorate at their next hospital admission.

The model scores each admission and produces a risk category:
- **Very High (>0.7):** 44.1% actually deteriorated at next admission
- **High (0.5-0.7):** 26.2% actually deteriorated
- **Moderate (0.3-0.5):** 23.3% actually deteriorated
- **Low (<0.3):** 10.8% actually deteriorated

---

## Key Results

### MIMIC-III Training (2001-2012, ICU only)

| Model | AUC | 95% CI | F1 | Time |
|-------|-----|--------|----|------|
| XGBoost ★ | **0.853** | [0.818, 0.884] | 0.587 | 0.8s |
| LightGBM | 0.847 | [0.812, 0.880] | 0.567 | 0.3s |
| Gradient Boosting | 0.829 | [0.792, 0.863] | 0.556 | 3.1s |
| Random Forest | 0.821 | [0.780, 0.860] | 0.534 | 0.7s |
| Logistic Regression | 0.762 | [0.721, 0.801] | 0.514 | <0.1s |
| Ghandian et al. 2022 (reference) | 0.871 | [0.859, 0.882] | — | retrospective |

### MIMIC-IV Temporal Validation (2008-2019)

| Experiment | Pairs | Positive% | AUC | 95% CI |
|-----------|-------|-----------|-----|--------|
| All 2008-2019 (COVID excluded) | 4,612 | 17.1% | **0.712** | [0.693, 0.732] |
| Early era 2008-2013 | 2,994 | 16.2% | 0.707 | [0.683, 0.731] |
| Post era 2014-2019 | 1,618 | 19.5% | 0.735 | [0.703, 0.767] |
| ICU admissions only | 973 | 16.3% | 0.755 | [0.713, 0.797] |
| Ward admissions only | 3,639 | 17.3% | 0.701 | [0.678, 0.724] |

### Ground Truth Verification

| Risk Category | Flagged | Actually Deteriorated | Rate |
|--------------|---------|----------------------|------|
| Very High (>0.7) | 551 | 243 | **44.1%** |
| High (0.5-0.7) | 351 | 92 | 26.2% |
| Moderate (0.3-0.5) | 446 | 104 | 23.3% |
| Low (<0.3) | 3,264 | 351 | 10.8% |

### Architecture Comparison (MUMPS vs PostgreSQL)

| Metric | PostgreSQL | MUMPS ^PHD | Winner |
|--------|-----------|------------|--------|
| Feature extraction | 79s | **23.5s** | MUMPS (3.4x faster) |
| XGBoost AUC | **0.853** | 0.820 | Postgres (stat. equiv.) |
| Point lookup | ~40ms | **~2ms** | MUMPS (20x faster) |
| CIs overlap? | — | — | Yes — equivalent quality |

---

## Methodology Summary

### 1. Cohort Identification
- MIMIC-III: 3,382 liver patients, 5,505 admissions (ICD-9 codes)
- MIMIC-IV: 2,164 liver patients, 11,704 admissions (ICD-9 + ICD-10 codes)
- 24 ICD-9 codes + 40+ ICD-10 codes covering full liver disease spectrum

### 2. MELD Score Computation
```
MELD = 3.78×ln(bili) + 11.2×ln(INR) + 9.57×ln(creat) + 6.43
MELD-Na = MELD + 1.32×(137-Na) - 0.033×MELD×(137-Na)
```
- Peak bilirubin and creatinine within admission
- Last INR and sodium within admission
- UNOS constraints applied

### 3. Option C Composite Label
Label = 1 if ANY of:
1. Peak MELD-Na ≥ 25
2. MELD-Na increased ≥ 5 points between consecutive admissions
3. Hepatorenal syndrome (ICD: 5724 / K767)
4. Hepatic encephalopathy (ICD: 5722 / K720-K729)
5. Bleeding esophageal varices (ICD: 45620 / I850, I859)
6. Died in hospital AND peak MELD ≥ 15

### 4. Prospective Prediction Framework
- For each patient with ≥2 admissions
- At admission N, predict deterioration at admission N+1
- Features from admission N only (no future data)
- Patient-level 70/30 split — no patient in both train and test

### 5. Feature Engineering (77 features)
- Demographics (2)
- Current admission labs: MELD-Na, bilirubin, creatinine, INR, sodium (6)
- Ghandian lab history summaries × 10 labs (40+)
- MELD trajectory: slope, acceleration, std, consecutive increases (6)
- Clinical diagnosis flags (5)
- Medication context with route differentiation (8+)
- Utilization patterns (10)

### 6. Temporal Validation Approach
- MIMIC-IV anchor_year_group used for real calendar era assignment
- COVID era (2020-2022) excluded: 8.2% mortality outlier
- Experiments split by era, ICU vs ward, combined

---

## SQL Queries

All validation queries are in the [`sql/`](sql/) folder:
- `01_cohort_identification.sql` — ICD-9 + ICD-10 liver cohort
- `02_meld_computation.sql` — MELD-Na per admission (peak/last)
- `03_medication_flags.sql` — chronic vs acute medication split
- `04_mortality_validation.sql` — MELD band mortality verification
- `05_icu_ward_split.sql` — ICU vs ward breakdown
- `06_temporal_split.sql` — anchor_year_group temporal analysis
- `07_ground_truth_verification.sql` — verify model predictions

---

## Real Patient Cases Verified

| Patient | Score | Diagnosis | Outcome | Model Correct? |
|---------|-------|-----------|---------|----------------|
| 11345335 | 0.997 | Alcoholic cirrhosis + encephalopathy | DIED (hepatorenal) | ✓ YES |
| 10944305 | 0.996 | Hepatorenal syndrome | DIED (creat 4.5→6.7) | ✓ YES |
| 10670524 | 0.995 | Varices + hepatorenal | DIED (creat 1.3→11.9) | ✓ YES |
| 10521848 | 0.993 | Cirrhosis → encephalopathy → failure | DIED | ✓ YES |
| 11004856 | 0.985 | Post-transplant graft necrosis | DIED | ✓ YES |
| 10916044 | 0.997 | Liver cancer → DIC + sepsis | DIED same day | ✓ YES |
| 10382575 | 0.988 | Alcoholic hepatitis → severe sepsis | Survived (ICU) | ~ Partial |

---

## Data Requirements

Both datasets require PhysioNet credentialing:
- MIMIC-III v1.4: https://physionet.org/content/mimiciii/1.4/
- MIMIC-IV v2.0+: https://physionet.org/content/mimiciv/

**Data is NOT included in this repository.**

---

## Stack

- YottaDB r2.06 (MUMPS database, Docker) — canonical HIE store
- PostgreSQL 16 (analytics layer, OMOP-aligned hie.* schema)
- Python 3.12, XGBoost, LightGBM, scikit-learn, pandas
- Chart.js (results dashboard)

---

## Project Phases

- **Phase 1 (complete):** MIMIC-III training, AUC 0.853, MUMPS architecture validation
- **Phase 2 (complete):** MIMIC-IV temporal validation, AUC 0.712, ground truth verification
- **Phase 3 (planned):** LSTM sequence model on Google Colab (expected AUC 0.87-0.92)
- **Phase 4 (planned):** Transformer model 50-60M params (expected AUC 0.90-0.95)
- **Phase 5 (planned):** Live HL7 v2.9 ADT feed integration

---

## License

MIT. MIMIC data subject to PhysioNet credentialing — research use only.
