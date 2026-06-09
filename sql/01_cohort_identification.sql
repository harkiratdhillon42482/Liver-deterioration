-- ============================================================
-- Query 01: Liver Disease Cohort Identification
-- Works on both MIMIC-III (MIMICold) and MIMIC-IV (MIMICIV)
-- ============================================================

-- ICD-9 codes (MIMIC-III and early MIMIC-IV)
-- ICD-10 codes (MIMIC-IV 2015+)

-- MIMIC-IV: Total patients and admissions by ICD version
SELECT
    CASE
        WHEN d9.subject_id IS NOT NULL
         AND d10.subject_id IS NOT NULL THEN 'Both ICD-9 and ICD-10'
        WHEN d9.subject_id IS NOT NULL  THEN 'ICD-9 only'
        WHEN d10.subject_id IS NOT NULL THEN 'ICD-10 only'
    END                                                AS icd_source,
    COUNT(DISTINCT a.subject_id)                       AS n_patients,
    COUNT(DISTINCT a.hadm_id)                          AS n_admissions,
    SUM(a.hospital_expire_flag)                        AS deaths,
    ROUND(100.0*SUM(a.hospital_expire_flag)/COUNT(*),1) AS mortality_pct,
    ROUND(AVG(EXTRACT(EPOCH FROM
        (a.dischtime-a.admittime))/86400)::numeric,1)  AS avg_los_days
FROM hosp.admissions a
LEFT JOIN (
    SELECT DISTINCT subject_id FROM hosp.diagnoses_icd
    WHERE icd_version=9 AND icd_code IN (
        '5710','5711','5712','5713','5715','5716','5718','5719',
        '5720','5722','5724','5728','7891','5671','5723',
        '45620','45621','1550','1551','1552',
        '07054','07044','07032','07070'
    )
) d9 ON a.subject_id = d9.subject_id
LEFT JOIN (
    SELECT DISTINCT subject_id FROM hosp.diagnoses_icd
    WHERE icd_version=10 AND icd_code IN (
        'K700','K701','K702','K703','K704','K709',
        'K720','K721','K729',
        'K740','K741','K742','K743','K744','K745','K746',
        'K766','K767','K760',
        'B182','B1810','B1811','B1819',
        'I850','I859','K650','K659',
        'C220','C221','C222',
        'K710','K711','K712','K713','K714','K715','K717','K718','K719'
    )
) d10 ON a.subject_id = d10.subject_id
WHERE d9.subject_id IS NOT NULL OR d10.subject_id IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- ============================================================
-- Disease stage breakdown by ICD-10
-- ============================================================
SELECT
    CASE
        WHEN d.icd_code = 'K767'
            THEN '1_Hepatorenal Syndrome'
        WHEN d.icd_code IN ('K720','K721','K729')
            THEN '2_Hepatic Failure'
        WHEN d.icd_code IN ('I850','I859','K650','K659')
            THEN '3_Varices / SBP'
        WHEN d.icd_code IN ('K740','K741','K742','K743','K744','K745','K746')
            THEN '4_Cirrhosis'
        WHEN d.icd_code IN ('K700','K701','K702','K703','K704','K709')
            THEN '5_Alcoholic Liver Disease'
        WHEN d.icd_code IN ('B182','B1811','B1810','B1819')
            THEN '6_Chronic Viral Hepatitis'
        WHEN d.icd_code IN ('K760')
            THEN '7_Fatty Liver (NAFLD)'
        WHEN d.icd_code IN ('C220','C221','C222','C223','C224','C225','C227','C229')
            THEN '8_Liver Cancer (HCC)'
        WHEN d.icd_code IN ('K710','K711','K712','K713','K714','K715','K717','K718','K719')
            THEN '9_Toxic Liver Disease'
        ELSE 'Other'
    END                                            AS disease_stage,
    COUNT(DISTINCT d.subject_id)                   AS n_patients,
    COUNT(DISTINCT d.hadm_id)                      AS n_admissions
FROM hosp.diagnoses_icd d
WHERE d.icd_version = 10
  AND d.icd_code IN (
    'K767','K720','K721','K729','I850','I859','K650','K659',
    'K740','K741','K742','K743','K744','K745','K746',
    'K700','K701','K702','K703','K704','K709',
    'B182','B1811','B1810','B1819','K760',
    'C220','C221','C222','C223','C224','C225','C227','C229',
    'K710','K711','K712','K713','K714','K715','K717','K718','K719'
  )
GROUP BY 1
ORDER BY 1;

-- ============================================================
-- ICU vs Ward split for liver patients (MIMIC-IV)
-- ============================================================
SELECT
    CASE WHEN i.hadm_id IS NOT NULL
         THEN 'ICU admitted'
         ELSE 'Non-ICU (ward only)'
    END                                                 AS admission_type,
    COUNT(DISTINCT a.subject_id)                        AS n_patients,
    COUNT(DISTINCT a.hadm_id)                           AS n_admissions,
    SUM(a.hospital_expire_flag)                         AS deaths,
    ROUND(100.0*SUM(a.hospital_expire_flag)/COUNT(*),1) AS mortality_pct,
    ROUND(AVG(EXTRACT(EPOCH FROM
        (a.dischtime-a.admittime))/86400)::numeric,1)   AS avg_los_days
FROM hosp.admissions a
JOIN (
    SELECT DISTINCT hadm_id FROM hosp.diagnoses_icd
    WHERE (icd_version=10 AND icd_code IN (
        'K700','K701','K702','K703','K704','K709',
        'K720','K721','K729','K740','K741','K742',
        'K743','K744','K745','K746','K767','I850','I859',
        'K766','K760','B182','I850','I859','C220','C221'
    ))
    OR (icd_version=9 AND icd_code IN (
        '5710','5711','5712','5715','5722','5724','45620'
    ))
) liver ON a.hadm_id = liver.hadm_id
LEFT JOIN (SELECT DISTINCT hadm_id FROM icu.icustays) i
    ON a.hadm_id = i.hadm_id
GROUP BY 1
ORDER BY 1;
