-- ============================================================
-- Query 04: Mortality Validation by MELD Band
-- Validates that MELD-Na score correctly stratifies mortality
-- This was used to validate the Option C label thresholds
-- ============================================================

WITH liver_patients AS (
    SELECT DISTINCT subject_id FROM hosp.diagnoses_icd
    WHERE (icd_version=10 AND icd_code IN (
        'K700','K701','K702','K703','K704','K709',
        'K720','K721','K729','K740','K741','K742',
        'K743','K744','K745','K746','K766','K767',
        'K760','B182','I850','I859','C220','C221'
    ))
    OR (icd_version=9 AND icd_code IN (
        '5710','5711','5712','5715','5722','5724','45620',
        '5720','5723','07054','1550','5716','5718'
    ))
),

-- Compute MELD per admission
meld_per_adm AS (
    SELECT
        a.subject_id, a.hadm_id, a.admittime,
        a.hospital_expire_flag,
        LEAST(40, GREATEST(6, ROUND((
            3.78*LN(GREATEST(1.0,LEAST(82.0,b.peak_bili)))+
            11.2*LN(GREATEST(1.0,LEAST(10.0,i.last_inr)))+
            9.57*LN(GREATEST(1.0,LEAST(4.0,c.peak_creat)))+6.43+
            1.32*(137-GREATEST(125.0,LEAST(137.0,s.last_sodium)))-
            0.033*(3.78*LN(GREATEST(1.0,LEAST(82.0,b.peak_bili)))+
                   11.2*LN(GREATEST(1.0,LEAST(10.0,i.last_inr)))+
                   9.57*LN(GREATEST(1.0,LEAST(4.0,c.peak_creat)))+6.43)*
                  (137-GREATEST(125.0,LEAST(137.0,s.last_sodium)))
        )::numeric,1))) AS meld_na
    FROM hosp.admissions a
    JOIN (
        SELECT subject_id, hadm_id, MAX(valuenum) AS peak_bili
        FROM hosp.labevents
        WHERE itemid=50885 AND valuenum>0
        GROUP BY subject_id, hadm_id
    ) b ON a.subject_id=b.subject_id AND a.hadm_id=b.hadm_id
    JOIN (
        SELECT subject_id, hadm_id, MAX(valuenum) AS peak_creat
        FROM hosp.labevents
        WHERE itemid=50912 AND valuenum>0
        GROUP BY subject_id, hadm_id
    ) c ON a.subject_id=c.subject_id AND a.hadm_id=c.hadm_id
    JOIN (
        SELECT DISTINCT ON (subject_id, hadm_id)
            subject_id, hadm_id, valuenum AS last_inr
        FROM hosp.labevents
        WHERE itemid=51237 AND valuenum>0
        ORDER BY subject_id, hadm_id, charttime DESC
    ) i ON a.subject_id=i.subject_id AND a.hadm_id=i.hadm_id
    JOIN (
        SELECT DISTINCT ON (subject_id, hadm_id)
            subject_id, hadm_id, valuenum AS last_sodium
        FROM hosp.labevents
        WHERE itemid IN (50983,50824) AND valuenum>0
        ORDER BY subject_id, hadm_id, charttime DESC
    ) s ON a.subject_id=s.subject_id AND a.hadm_id=s.hadm_id
    WHERE a.subject_id IN (SELECT subject_id FROM liver_patients)
)

-- Mortality by MELD band
SELECT
    CASE
        WHEN meld_na <= 9  THEN '1_Low       (MELD  6-9)'
        WHEN meld_na <= 14 THEN '2_Mild      (MELD 10-14)'
        WHEN meld_na <= 19 THEN '3_Moderate  (MELD 15-19)'
        WHEN meld_na <= 24 THEN '4_High      (MELD 20-24)'
        WHEN meld_na <= 29 THEN '5_Very High (MELD 25-29)'
        WHEN meld_na <= 39 THEN '6_Severe    (MELD 30-39)'
        ELSE                    '7_Maximum   (MELD 40)'
    END                                                 AS meld_band,
    COUNT(DISTINCT subject_id)                          AS n_patients,
    COUNT(*)                                            AS n_admissions,
    SUM(hospital_expire_flag)                           AS deaths,
    ROUND(100.0*SUM(hospital_expire_flag)/COUNT(*),1)   AS mortality_pct,
    ROUND(AVG(meld_na)::numeric, 1)                     AS avg_meld_na,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP
          (ORDER BY meld_na)::numeric, 1)               AS median_meld_na
FROM meld_per_adm
WHERE meld_na IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- ============================================================
-- Complications in MELD >= 30 deaths
-- Used to validate Option C label criteria
-- ============================================================
SELECT
    d.icd_code,
    di.long_title,
    COUNT(DISTINCT d.subject_id) AS n_patients
FROM hosp.diagnoses_icd d
JOIN hosp.d_icd_diagnoses di
    ON d.icd_code=di.icd_code AND d.icd_version=di.icd_version
WHERE d.subject_id IN (
    -- Patients who died with MELD >= 30
    SELECT DISTINCT m.subject_id
    FROM meld_per_adm m  -- requires WITH clause above to be included
    JOIN hosp.admissions a ON m.hadm_id=a.hadm_id
    WHERE m.meld_na >= 30 AND a.hospital_expire_flag=1
)
GROUP BY d.icd_code, di.long_title
ORDER BY n_patients DESC
LIMIT 20;
