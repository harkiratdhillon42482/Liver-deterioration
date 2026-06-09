-- ============================================================
-- Query 05: Temporal Split Using anchor_year_group
-- MIMIC-IV dates are shifted for privacy
-- anchor_year_group gives the real calendar era
-- ============================================================

-- Verify hadm_id is shared between hosp and icu schemas
SELECT
    'hosp.admissions'    AS source,
    COUNT(*)             AS total_hadm_ids,
    COUNT(DISTINCT hadm_id) AS unique_hadm_ids,
    MIN(hadm_id)         AS min_hadm_id,
    MAX(hadm_id)         AS max_hadm_id
FROM hosp.admissions
UNION ALL
SELECT
    'icu.icustays'       AS source,
    COUNT(*)             AS total_hadm_ids,
    COUNT(DISTINCT hadm_id) AS unique_hadm_ids,
    MIN(hadm_id)         AS min_hadm_id,
    MAX(hadm_id)         AS max_hadm_id
FROM icu.icustays
UNION ALL
SELECT
    'overlap (in both)'  AS source,
    COUNT(*)             AS total_hadm_ids,
    COUNT(DISTINCT a.hadm_id) AS unique_hadm_ids,
    MIN(a.hadm_id)       AS min_hadm_id,
    MAX(a.hadm_id)       AS max_hadm_id
FROM hosp.admissions a
INNER JOIN icu.icustays i ON a.hadm_id = i.hadm_id;

-- ============================================================
-- Liver patients by real calendar era (anchor_year_group)
-- ============================================================
SELECT
    p.anchor_year_group,
    COUNT(DISTINCT a.subject_id)                         AS n_patients,
    COUNT(DISTINCT a.hadm_id)                            AS n_admissions,
    SUM(a.hospital_expire_flag)                          AS deaths,
    ROUND(100.0*SUM(a.hospital_expire_flag)/COUNT(*),1)  AS mortality_pct,
    ROUND(AVG(EXTRACT(EPOCH FROM
        (a.dischtime-a.admittime))/86400)::numeric,1)    AS avg_los_days
FROM hosp.admissions a
JOIN hosp.patients p ON a.subject_id = p.subject_id
JOIN (
    SELECT DISTINCT hadm_id FROM hosp.diagnoses_icd
    WHERE (icd_version=9 AND icd_code IN (
        '5710','5711','5712','5715','5722','5724','45620',
        '5720','5723','07054','1550','5716','5718'
    ))
    OR (icd_version=10 AND icd_code IN (
        'K700','K701','K702','K703','K704','K709',
        'K720','K721','K729','K740','K741','K742',
        'K743','K744','K745','K746','K766','K767',
        'K760','B182','I850','I859','C220','C221'
    ))
) liver ON a.hadm_id = liver.hadm_id
GROUP BY p.anchor_year_group
ORDER BY p.anchor_year_group;

-- ============================================================
-- Admission count distribution (for prospective pair estimation)
-- COVID era (2020-2022) excluded
-- ============================================================
SELECT
    CASE
        WHEN n_adm = 1   THEN '1_one admission'
        WHEN n_adm <= 3  THEN '2_two-three admissions'
        WHEN n_adm <= 5  THEN '3_four-five admissions'
        WHEN n_adm <= 10 THEN '4_six-ten admissions'
        ELSE                  '5_ten plus admissions'
    END                                      AS bucket,
    COUNT(*)                                 AS n_patients,
    ROUND(100.0*COUNT(*)/SUM(COUNT(*))
          OVER(),1)                          AS pct,
    SUM(n_adm)                               AS total_admissions
FROM (
    SELECT a.subject_id, COUNT(DISTINCT a.hadm_id) AS n_adm
    FROM hosp.admissions a
    JOIN hosp.patients p ON a.subject_id = p.subject_id
    JOIN (
        SELECT DISTINCT hadm_id FROM hosp.diagnoses_icd
        WHERE (icd_version=9 AND icd_code IN (
            '5710','5711','5712','5715','5722','5724','45620',
            '5720','5723','07054','1550','5716','5718'
        ))
        OR (icd_version=10 AND icd_code IN (
            'K700','K701','K702','K703','K704','K709',
            'K720','K721','K729','K740','K741','K742',
            'K743','K744','K745','K746','K766','K767',
            'I850','I859','K650','C220','C221'
        ))
    ) liver ON a.hadm_id = liver.hadm_id
    WHERE p.anchor_year_group != '2020 - 2022'
    GROUP BY a.subject_id
) t
GROUP BY bucket
ORDER BY bucket;
