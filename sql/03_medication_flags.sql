-- ============================================================
-- Query 03: Medication Features — Chronic vs Acute Split
-- Route-based classification:
--   Oral (PO/PO/NG) = chronic outpatient proxy
--   IV/IV DRIP      = acute inpatient escalation
-- ============================================================

-- Chronic vs acute medication distribution
-- for ICU vs ward liver patients
SELECT
    admit_type,
    drug_category,
    COUNT(DISTINCT subject_id)   AS n_patients,
    COUNT(*)                     AS n_prescriptions
FROM (
    SELECT
        p.subject_id,
        p.hadm_id,
        CASE WHEN i.hadm_id IS NOT NULL
             THEN 'ICU' ELSE 'Ward' END AS admit_type,
        CASE
            -- ACUTE medications (IV route = inpatient initiated)
            WHEN LOWER(p.drug) LIKE '%albumin%'
                 AND p.route IN ('IV','IV DRIP','IV INFUSION')
                 THEN 'albumin_iv_acute'
            WHEN LOWER(p.drug) LIKE '%vasopressin%'
                 AND p.route IN ('IV','IV DRIP','IV INFUSION')
                 THEN 'vasopressin_iv_acute'
            WHEN LOWER(p.drug) LIKE '%furosemide%'
                 AND p.route IN ('IV','IV DRIP','IV BOLUS')
                 THEN 'furosemide_iv_acute'
            WHEN LOWER(p.drug) LIKE '%octreotide%'
                 THEN 'octreotide_acute'
            WHEN LOWER(p.drug) LIKE '%ciprofloxacin%'
                 AND p.route IN ('IV','IV DRIP')
                 THEN 'cipro_iv_acute'

            -- CHRONIC medications (oral route = pre-existing management)
            WHEN LOWER(p.drug) LIKE '%furosemide%'
                 AND p.route IN ('PO','PO/NG','ORAL','NG')
                 THEN 'furosemide_po_chronic'
            WHEN LOWER(p.drug) LIKE '%lactulose%'
                 THEN 'lactulose_oral_chronic'
            WHEN LOWER(p.drug) LIKE '%rifaximin%'
                 THEN 'rifaximin_oral_chronic'
            WHEN LOWER(p.drug) LIKE '%spironolactone%'
                 THEN 'spironolactone_oral_chronic'
            WHEN LOWER(p.drug) LIKE '%midodrine%'
                 THEN 'midodrine_oral_chronic'
            WHEN (LOWER(p.drug) LIKE '%nadolol%'
                 OR LOWER(p.drug) LIKE '%propranolol%')
                 AND p.route IN ('PO','PO/NG','ORAL','NG')
                 THEN 'betablocker_oral_chronic'
            ELSE NULL
        END AS drug_category
    FROM hosp.prescriptions p
    JOIN (
        SELECT DISTINCT hadm_id FROM hosp.diagnoses_icd
        WHERE (icd_version=10 AND icd_code IN (
            'K700','K701','K702','K703','K704','K709',
            'K720','K721','K729','K740','K741','K742',
            'K743','K744','K745','K746','K766','K767',
            'K760','B182','I850','I859','C220','C221'
        ))
        OR (icd_version=9 AND icd_code IN (
            '5710','5711','5712','5715','5722','5724','45620'
        ))
    ) liver ON p.hadm_id = liver.hadm_id
    LEFT JOIN (
        SELECT DISTINCT hadm_id FROM icu.icustays
    ) i ON p.hadm_id = i.hadm_id
) t
WHERE drug_category IS NOT NULL
GROUP BY admit_type, drug_category
ORDER BY drug_category, admit_type;

-- ============================================================
-- Escalation pattern: patients on BOTH oral and IV furosemide
-- This captures the transition from outpatient to acute management
-- ============================================================
SELECT
    p.subject_id,
    p.hadm_id,
    MAX(CASE WHEN LOWER(p.drug) LIKE '%furosemide%'
             AND p.route IN ('PO','PO/NG','ORAL','NG')
             THEN 1 ELSE 0 END) AS on_furosemide_oral,
    MAX(CASE WHEN LOWER(p.drug) LIKE '%furosemide%'
             AND p.route IN ('IV','IV DRIP','IV BOLUS')
             THEN 1 ELSE 0 END) AS on_furosemide_iv
FROM hosp.prescriptions p
WHERE p.subject_id IN (
    SELECT DISTINCT subject_id FROM hosp.diagnoses_icd
    WHERE icd_version=10 AND icd_code IN (
        'K743','K744','K745','K746','K766','K767'
    )
)
GROUP BY p.subject_id, p.hadm_id
HAVING MAX(CASE WHEN LOWER(p.drug) LIKE '%furosemide%'
                AND p.route IN ('PO','PO/NG','ORAL','NG')
                THEN 1 ELSE 0 END) = 1
   AND MAX(CASE WHEN LOWER(p.drug) LIKE '%furosemide%'
                AND p.route IN ('IV','IV DRIP','IV BOLUS')
                THEN 1 ELSE 0 END) = 1
ORDER BY p.subject_id, p.hadm_id;
